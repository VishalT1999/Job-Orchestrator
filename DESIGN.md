# DESIGN.md — Amaha Job Orchestrator

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Core Architecture](#2-core-architecture)
3. [State Machine Design](#3-state-machine-design)
4. [Concurrency & Distributed Locking](#4-concurrency--distributed-locking)
5. [Fairness Scheduling — Weighted Fair Queuing](#5-fairness-scheduling--weighted-fair-queuing)
6. [Dead Man's Switch (Heartbeat)](#6-dead-mans-switch-heartbeat)
7. [Retry Semantics & Idempotency](#7-retry-semantics--idempotency)
8. [Scaling to 100k Jobs/Hour](#8-scaling-to-100k-jobshour)
9. [Failure Mode Analysis](#9-failure-mode-analysis)
10. [Abuse Protection](#10-abuse-protection)
11. [Observability](#11-observability)
12. [Implementation Notes](#12-implementation-notes)

---

## 1. System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          API Layer (Rails)                           │
│   POST /jobs ──→ RateLimiter ──→ persist (queued) ──→ kick Dispatch │
│   GET  /health/detailed ──→ DB + Redis + Sidekiq latency check       │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │    MySQL (source of     │
              │    truth for all state) │
              └────────────┬────────────┘
                           │
   ┌───────────────────────▼────────────────────────────────────┐
   │                  Sidekiq Process(es)                        │
   │                                                             │
   │  ┌──────────────────┐    ┌───────────────────────────────┐  │
   │  │ JobDispatcher    │    │  HeartbeatMonitor             │  │
   │  │ every 5s + kick  │    │  every 15 s · SKIP LOCKED     │  │
   │  │                  │    │                               │  │
   │  │ FairnessScheduler│    │ stalls jobs silent > 60 s     │  │
   │  │ ConcurrencyGuard │    │ fallback: DB last_heartbeat   │  │
   │  └───────┬──────────┘    └───────────────────────────────┘  │
   │          │                                                   │
   │          ▼                                                   │
   │  ┌──────────────────┐    ┌───────────────────────────────┐  │
   │  │ JobExecutor      │    │ RetryJobWorker                │  │
   │  │ runs workload    │    │ requeue! + re-trigger         │  │
   │  │ pulse HB / 20 s  │    │ JobDispatcherWorker           │  │
   │  └──────────────────┘    └───────────────────────────────┘  │
   └─────────────────────────────────────────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │    Redis                │
              │  • Sidekiq job queues   │
              │  • Redlock mutex keys   │
              │  • Heartbeat TTL keys   │
              │  • Rate limit windows   │
              │  • VFT counters         │
              └─────────────────────────┘
```

**Key design principle**: MySQL is the **single source of truth** for all job state.
Redis is an acceleration layer — losing it degrades performance but never corrupts state.

---

## 2. Core Architecture

### Separation of Scheduler and Executor

| Role | Worker | Queue | Concurrency |
|------|--------|-------|-------------|
| **Scheduler** | `JobDispatcherWorker` | `:scheduler` | 1 |
| **Executor** | `JobExecutorWorker` | `:executor` | N (configurable) |
| **Monitor** | `HeartbeatMonitorWorker` | `:monitor` | 1 |
| **Retry** | `RetryJobWorker` | `:scheduler` | 1 (shared with dispatcher) |

The Scheduler runs every 5 seconds on a **single Sidekiq thread** (queue concurrency: 1).
This serialises scheduling decisions and eliminates thundering-herd contention.

On every `POST /jobs`, `JobDispatcherWorker.perform_async` is called immediately — the job
doesn't wait up to 5 seconds for the next cron tick.

### RetryJobWorker → Dispatcher (not a new job)

After `requeue!`, `RetryJobWorker` calls `JobDispatcherWorker.perform_async` to re-trigger
the **existing scheduler**. It does not create a new executor directly. This preserves the
invariant that all scheduling decisions go through `FairnessScheduler` and `ConcurrencyGuard`.

---

## 3. State Machine Design

```
                        ┌─────────┐
                        │  queued │ ◄─────────────────────────┐
                        └────┬────┘                           │
                             │ start!                         │
                             │ (guard: quota available)        │ requeue!
                             ▼                                │ (guard: retries_remaining?)
                        ┌─────────┐                           │
                        │ running │ ──────────────────────────┤
                        └────┬────┘                      ┌────┴────┐   ┌────────┐
                             │                           │ failed  │   │stalled │
               ┌─────────────┼──────────────┐           └─────────┘   └────────┘
               │             │              │
          complete!     mark_failed!      stall!
               │             │              │
               ▼             ▼              ▼
          ┌─────────┐  ┌─────────┐  ┌─────────┐
          │completed│  │ failed  │  │ stalled │
          └─────────┘  └─────────┘  └─────────┘
```

### State machine gem: state_machines-activerecord

We use `state_machines-activerecord` (not AASM) because:

- Guards use `if:` on the transition definition — explicit and readable
- `after_transition on: :event` callbacks receive the full transition object
- Non-bang methods return `false` on invalid transition; bang methods raise `StateMachines::InvalidTransition`
- Direct integration with ActiveRecord validations and dirty tracking

**Critical naming note**: The `fail` event was renamed to `mark_failed` because `fail` is an
alias for `Kernel#raise` in Ruby. Calling `job.fail!` would raise `RuntimeError` instead of
triggering the state machine.

### Guards Preventing Illegal Transitions

- **`state_machines` `if:` guard** on `start!`: `concurrency_quota_available?`
- **Optimistic locking** (`lock_version`): two concurrent writers — one raises `ActiveRecord::StaleObjectError`
- **`FOR UPDATE SKIP LOCKED`** (MySQL): scheduler and monitor grab different rows, never blocking each other
- **`DbLock` helper**: wraps all `FOR UPDATE` clauses so they become no-ops on SQLite (test env) without code changes

### Crash Recovery

- **SIGKILL during `queued → running`**: DB transaction hasn't committed; job stays `queued`
- **SIGKILL during `running → completed`**: job stays `running`; heartbeat stops; monitor stalls it after 60 s; retry kicks in
- No window where a job is permanently lost

---

## 4. Concurrency & Distributed Locking

### Why Not a Redis Counter?

A Redis `INCR`/`DECR` counter leaks when a worker is killed after incrementing but before decrementing, and resets to 0 on `FLUSHALL` while jobs are still running.

**Our approach**: the running count is always a live DB query:

```ruby
Job.where(client_id: client_id, state: "running").count
```

No counter can drift. A `FLUSHALL` cannot cause quota leaks.

### Redlock for Mutual Exclusion

Redlock mutex on `concurrency:<client_id>` prevents two schedulers on different hosts from
simultaneously counting N running jobs and both starting a new one.

Inside the lock:
1. `SELECT ... FOR UPDATE SKIP LOCKED` on the job row
2. `COUNT(*)` running jobs (always live from DB)
3. Compare against `clients.concurrency_limit` (always live — picks up quota reductions immediately)
4. `start!` inside the same transaction
5. Release Redlock

### DbLock Helper

All `FOR UPDATE` and `FOR UPDATE SKIP LOCKED` clauses go through `DbLock.for_update` and
`DbLock.skip_locked`. On MySQL these return the SQL clause; on SQLite they return `nil` and
the lock is skipped. This keeps production locking correct and tests runnable without MySQL.

```ruby
lock  = DbLock.skip_locked
fresh = lock ? Job.lock(lock).find_by(...) : Job.find_by(...)
```

---

## 5. Fairness Scheduling — Weighted Fair Queuing

### Problem

A client submitting 10,000 jobs starves all other clients in a naive FIFO queue.

### Algorithm: Virtual Finish Time (VFT)

Each client has a VFT counter in Redis. On dispatch:

```
VFT[client] += 1 / priority_weight(job)
```

`priority_weight`: high = 3, medium = 2, low = 1.

The scheduler picks the **client with the lowest VFT** and their highest-priority runnable job.

**Effect:**
- Clients served in round-robin when VFTs are equal
- High-priority jobs increment VFT by only 1/3 — the client stays competitive longer
- A flooding client accumulates VFT rapidly and is deprioritised
- VFTs have a 24-hour TTL; a Redis flush resets all to 0 — full fairness restored instantly

### Example

| Tick | Client A VFT | Client B VFT | Selected |
|------|-------------|-------------|---------|
| 1    | 0           | 0           | A |
| 2    | 0.33 (high) | 0           | B |
| 3    | 0.33        | 0.50 (med)  | A |
| 4    | 0.66        | 0.50        | B |

### DB-agnostic priority ordering

`FIELD(priority, 'high', 'medium', 'low')` is MySQL-only. The `by_priority` scope uses
`CASE WHEN` so it works on both MySQL (production) and SQLite (test):

```ruby
PRIORITY_ORDER_SQL = Arel.sql(
  "CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END"
)
```

---

## 6. Dead Man's Switch (Heartbeat)

```
JobExecutorWorker
│
├── workload_thread = Thread.new { run_workload() }
│
└── loop every 20s:
    ├── HeartbeatService.pulse(job_id)
    │     → Redis key (TTL 90s)
    │     → DB last_heartbeat_at column (durable fallback)
    └── wait for workload_thread.join(20s)
```

### HeartbeatService design

- `initialize(redis_pool: nil)` — **lazy Redis init**: `@redis_pool ||= RedisPool.instance` on first use
  — construction never raises even when Redis is unavailable
- `with_redis` wraps every Redis call in a rescue for `CannotConnectError` — falls back gracefully to DB
- `clear(job_id)` nulls **both** the Redis key **and** the DB `last_heartbeat_at` column, called **outside** the DB transaction to avoid Redis ops being entangled with DB rollback

### Split-brain protection

`FOR UPDATE SKIP LOCKED` means two monitor workers processing the same tick will claim different
stale jobs. If two monitors somehow both load the same job, optimistic locking (`lock_version`)
ensures only one `stall!` commits.

### Frozen worker (long GC pause)

```
T+0:00  Worker starts job. Heartbeat recorded.
T+0:20  GC pause begins. No pulse.
T+1:00  HeartbeatMonitor stalls the job. RetryJobWorker scheduled.
T+2:00  GC pause ends. Worker resumes.
         job.running? → false (job is stalled). Worker exits cleanly.
T+??    RetryJobWorker fires. requeue! → queued. Dispatcher picks it up.
```

---

## 7. Retry Semantics & Idempotency

### At-Least-Once Processing

We use at-least-once semantics with idempotency guards. A job may execute more than once only if:
- A worker crashes after starting but before committing `completed`
- A GC pause causes a stall and retry

Workloads should use the `workload` field as an idempotency key in downstream systems.

### Exponential Backoff

```
delay = min(2^retry_count * 30, 3600) seconds

attempt 0 →   30 s
attempt 1 →   60 s
attempt 2 →  120 s
attempt 3 →  240 s
...capped at 3600 s (1 hour)
```

### RetryJobWorker flow

1. `job.reload` — ensures in-memory state machine matches DB (critical when job was created by FactoryBot or another process writing the column directly)
2. Early return if already `queued?`, `running?`, or `completed?`
3. `requeue!` inside a DB transaction with adapter-aware locking
4. `JobDispatcherWorker.perform_async` — re-triggers the existing scheduler (does not create a new job or executor directly)

### Sidekiq retries disabled on executor

`JobExecutorWorker` has `retry: 0`. Our own retry (exponential backoff + quota awareness + idempotency) is more sophisticated than Sidekiq's immediate retry. `RetryJobWorker` has `retry: 3` (Sidekiq-level) since it's a lightweight transition and transient DB errors should retry quickly.

---

## 8. Scaling to 100k Jobs/Hour

100k/hour ≈ 28 jobs/second.

### Scheduler throughput

Single scheduler dispatching 50 jobs/tick at 5-second intervals = 10/second from one process.
For 28/second:

**Option A** — reduce tick interval to 2 seconds (covers ~25/second from one process).

**Option B** — shard scheduler by `client_id`:
```
Shard 0: CRC32(client_id) % 4 == 0
Shard 1: CRC32(client_id) % 4 == 1
...
```
Each shard uses a distinct Redlock key. Scales linearly.

### Redis contention

| Operation | Rate | Notes |
|-----------|------|-------|
| Redlock acquire/release | 28/s | Shard by client_id |
| Heartbeat pulse | #running × 1/20 | Pipeline Redis + DB update |
| VFT INCRBYFLOAT | 28/s | O(1), no contention |
| Rate limit pipeline | per submission | 4 ops, pipelined |

Single Redis handles 100k jobs/hour comfortably. For 1M+/hour: shard Redis by `client_id` hash.
All keys are already namespaced by `client_id` so sharding is straightforward.

### Database scaling

The scheduling query uses `idx_jobs_scheduling` on `(state, priority, run_at)`.

For large tables: partition `jobs` by `created_at` month. Archive `completed`/`failed` rows
to a separate table. Add a read replica for health checks and status queries.

### Connection pool sizing

`RedisPool` size is configurable via `REDIS_POOL_SIZE` env var (default 10). Set to
`RAILS_MAX_THREADS + Sidekiq concurrency` so every thread can always get a connection.

---

## 9. Failure Mode Analysis

### A. Redis `FLUSHALL`

| Component | Impact | Recovery |
|-----------|--------|----------|
| Sidekiq queues | All pending jobs lost | Dispatcher re-enqueues in ≤5 s via cron |
| Heartbeat keys | Lost | Monitor falls back to DB `last_heartbeat_at` column |
| VFT counters | Reset to 0 | Full fairness restored instantly |
| Rate limit windows | Reset | Brief free burst; windows refill in 60 s |
| **Concurrency slots** | **Not in Redis** | **No impact** |

### B. Split-brain: two workers stall the same job

`FOR UPDATE SKIP LOCKED` → one gets the row, one gets nil and exits.
If both somehow load the job: optimistic lock (`lock_version`) → one UPDATE succeeds, one raises `StaleObjectError` → rescued and logged. Job stalled exactly once.

### C. Frozen worker (2-minute GC pause)

See §6. Job stalled at T+60s. Retried after backoff. Frozen worker exits cleanly on resume.

### D. Worker SIGKILL during transition

DB transaction rolls back. Job stays in previous state. Monitor catches orphaned running jobs. No permanent loss.

### E. Redis unavailable at service startup

`HeartbeatService` lazy-initialises Redis. `with_redis` rescues connection errors. Monitor runs DB-only checks. System degrades gracefully — no crash, no panic.

---

## 10. Abuse Protection

### Scenario: 1 million jobs in 10 seconds

**Layer 1 — Rate limiter** (immediate): client blocked after N req/min. `429` with `Retry-After`.

**Layer 2 — WFQ** (execution): flooding client accumulates VFT rapidly. Other clients served preferentially.

**Layer 3 — Concurrency quota** (execution): client runs at most N jobs concurrently regardless of queue depth.

**Layer 4 — Admin controls**: set `rate_limit_per_minute = 0` to block submissions; `concurrency_limit = 0` to pause execution.

---

## 11. Observability

### Health endpoint: `GET /health/detailed`

Returns `200 OK` only when all three components are healthy. Returns `503` if any fails:

- **Database**: live `SELECT 1` with connection pool stats
- **Redis**: live `PING` with version and memory usage
- **Sidekiq**: default queue latency. `503` if latency > 15 seconds

### Structured logging

All services log with `job_id`, `client_id`, `state`, `worker_id`. Every state transition is
logged via `state_machines` `after_transition` hook:

```
[Job#42] queued → running via :start (client=acme)
```

---

## 12. Implementation Notes

### Test environment

The test database uses **SQLite** (no MySQL server required for CI). All SQL is written for
portability:

- `CASE WHEN` instead of `FIELD()` for priority ordering
- `DbLock` helper returns `nil` on SQLite (no `FOR UPDATE`)
- Adapter check: `ActiveRecord::Base.connection.adapter_name =~ /mysql/i`

### FactoryBot + state_machines

`state_machines-activerecord` intercepts `before_save` and resets the state column to
`initial: :queued` on new records. Factory traits that set a non-default state must use
`update_column` after create:

```ruby
after(:create) do |job|
  intended = job.read_attribute(:state)
  job.update_column(:state, intended)
  job.reload   # sync in-memory state machine
end
```

### MockRedis isolation

Each spec gets a fresh `MockRedis` instance. Services that call `RedisPool.instance` multiple
times within one request (e.g. `HeartbeatService#pulse` then `#last_heartbeat`) must use the
**same** instance — achieved by memoizing: `@redis_pool ||= RedisPool.instance`.

### Redis ops outside DB transactions

Redis operations (`HeartbeatService#clear`) are deliberately placed **outside** `ActiveRecord::Base.transaction` blocks. Redis is not transactional — a DB rollback cannot undo a Redis `DEL`. The correct order is: commit DB state first, then update Redis.

---

## Technology Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| State machine gem | `state_machines-activerecord` | `if:` guards, transition object in callbacks, soft/bang variants, no `Kernel#fail` conflict |
| `fail` event name | `mark_failed` | `fail` aliases `Kernel#raise` in Ruby — `job.fail!` raises RuntimeError |
| Priority ordering SQL | `CASE WHEN` | `FIELD()` is MySQL-only; `CASE WHEN` works on MySQL + SQLite |
| Concurrency tracking | DB row count | No drift, no leaks, Redis-flush safe |
| Distributed lock | Redlock | De-facto standard for Redis-backed distributed mutexes |
| Fairness | Weighted Fair Queuing (VFT) | Prevents starvation, proportional to priority |
| Heartbeat storage | Redis TTL + DB column | Redis is fast; DB column is the fallback |
| Redis init | Lazy (`\|\|=`) | Construction never raises when Redis is unavailable |
| Redis ops placement | Outside DB transactions | Redis not transactional; DB commit first, then Redis |
| Retry trigger | `RetryJobWorker` → `JobDispatcherWorker.perform_async` | Preserves scheduling invariants — all jobs go through WFQ + quota |
| Scheduler architecture | Single-threaded poller | Eliminates thundering herd; shardable if needed |
| Locking SQL | `DbLock` helper | `FOR UPDATE SKIP LOCKED` on MySQL; no-op on SQLite |
| Test database | SQLite | No MySQL server needed for CI; all SQL is portable |