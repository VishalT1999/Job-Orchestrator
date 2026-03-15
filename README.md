# Job Orchestrator

A distributed job orchestration system built with Ruby on Rails, MySQL, Redis, and Sidekiq.
Implements dynamic concurrency quotas, weighted fair queuing, heartbeat-based stall detection,
and exponential-backoff retries.

## Stack

- **Ruby** 3.2.2 / **Rails** 7.1
- **MySQL** 8.0 — source of truth for all job state
- **Redis** 7.0 — acceleration layer (queues, locks, heartbeats, VFT counters)
- **Sidekiq** 7.2 + **sidekiq-scheduler** — background workers and cron
- **state_machines-activerecord** — guarded linear state machine
- **Redlock** — distributed mutex for concurrency quota enforcement

## Requirements

- Ruby 3.2.2
- MySQL 8.0+
- Redis 7.0+

## Setup

```bash
bundle install
cp .env.example .env          # edit DB/Redis URLs as needed
RAILS_ENV=development rails db:create db:migrate
rails db:seed                  # creates sample clients
```

## Running

**API server:**
```bash
rails server
```

**Sidekiq workers:**
```bash
bundle exec sidekiq -C config/sidekiq.yml
```

Both must be running for end-to-end job execution.

## API

### Submit a job

```bash
curl -X POST http://localhost:3000/api/v1/jobs \
  -H "Content-Type: application/json" \
  -d '{"job": {"client_id": "acme", "priority": "high", "workload": "fast_task"}}'
```

Response (immediate — no waiting):
```json
{
  "id": 42,
  "client_id": "acme",
  "priority": "high",
  "workload": "fast_task",
  "state": "queued",
  "created_at": "2024-01-15T10:00:00Z"
}
```

### Get job status

```bash
curl http://localhost:3000/api/v1/jobs/42
```

### Health check

```bash
curl http://localhost:3000/health/detailed
```

Returns `200 OK` when healthy. Returns `503 Service Unavailable` when:
- Database connection fails
- Redis connection fails
- Sidekiq default queue latency > 15 seconds

## Job lifecycle

```
queued → running → completed
                 → failed   → requeue! (backoff) → queued
                 → stalled  → requeue! (backoff) → queued
```

- **Illegal transitions are rejected** — `state_machines` raises `StateMachines::InvalidTransition`
- **Optimistic locking** (`lock_version`) prevents concurrent double-transitions
- **`FOR UPDATE SKIP LOCKED`** prevents two workers from stalling the same job simultaneously (MySQL; no-op on SQLite in tests)

## Workers

| Worker | Queue | Runs | Purpose |
|--------|-------|------|---------|
| `JobDispatcherWorker` | `:scheduler` | Every 5 s + on submit | Picks next job via WFQ, acquires concurrency slot, enqueues executor |
| `JobExecutorWorker` | `:executor` | On dispatch | Runs workload, pulses heartbeat every 20 s |
| `HeartbeatMonitorWorker` | `:monitor` | Every 15 s | Stalls jobs silent for > 60 s |
| `RetryJobWorker` | `:scheduler` | After backoff delay | Requeues failed/stalled jobs, re-triggers dispatcher |

## Scheduling — Weighted Fair Queuing

Each client has a **Virtual Finish Time (VFT)** counter in Redis. On each dispatch:

```
VFT[client] += 1 / priority_weight
```

`priority_weight`: high = 3, medium = 2, low = 1.

The scheduler picks the client with the **lowest VFT** and their highest-priority runnable job. A client flooding the queue accumulates VFT rapidly and is deprioritised — other clients are never starved.

## Concurrency quota enforcement

Slot counting is always a **live DB `COUNT(*)`** — never a Redis counter. A Redis `FLUSHALL` cannot leak slots or cause over-provisioning.

Flow inside `ConcurrencyGuard#acquire!`:
1. Acquire Redlock on `concurrency:<client_id>`
2. `SELECT ... FOR UPDATE SKIP LOCKED` on the job row
3. `COUNT(*)` running jobs for the client
4. Compare against `clients.concurrency_limit` (live from DB — quota reductions take effect immediately)
5. Transition `start!` inside the same DB transaction
6. Release Redlock

## Heartbeat (Dead Man's Switch)

- Workers pulse every **20 seconds** to Redis (TTL 90 s) and the DB `last_heartbeat_at` column
- `HeartbeatMonitorWorker` runs every **15 seconds**, stalls any job silent for **> 60 seconds**
- After stalling, `RetryJobWorker` is scheduled with exponential backoff
- Redis flush resilience: monitor falls back to the DB column if the Redis key is missing

## Retry semantics

```
delay = min(2^retry_count * 30, 3600) seconds
```

| Attempt | Delay |
|---------|-------|
| 1 | 30 s |
| 2 | 60 s |
| 3 | 120 s |
| … | … capped at 1 h |

Retries go through the full `ConcurrencyGuard` path — no fast lane. `RetryJobWorker` calls `requeue!` then `JobDispatcherWorker.perform_async` to re-trigger the existing scheduler (not enqueue a new job).

## Rate limiting

Sliding-window rate limiter in Redis. Returns `429 Too Many Requests` with `Retry-After` header before a flood reaches MySQL.

Default: 100 submissions/minute per client. Configurable via `clients.rate_limit_per_minute`.

## Running tests

```bash
# All specs
bundle exec rspec

# By layer
bundle exec rspec spec/models/
bundle exec rspec spec/services/
bundle exec rspec spec/workers/
bundle exec rspec spec/requests/

# Verbose
bundle exec rspec --format documentation
```

Test database uses **SQLite** (no MySQL server required). All SQL uses `CASE WHEN` instead of `FIELD()` for portability.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `mysql2://root@localhost/storage/development.sqlite3` | MySQL connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `REDIS_POOL_SIZE` | `10` | Redis connection pool size |
| `RAILS_MAX_THREADS` | `5` | Puma thread count |
| `DB_USERNAME` | `root` | MySQL username |
| `DB_PASSWORD` | _(empty)_ | MySQL password |
| `DB_HOST` | `127.0.0.1` | MySQL host |

## Architecture

See [DESIGN.md](DESIGN.md) for full architectural reasoning, failure mode analysis, and scaling strategy.