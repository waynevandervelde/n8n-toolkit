# n8n Queue Mode — Scalable and Reliable Workflow Automation

Unleash the full potential of n8n by running it in **Queue Mode**, where execution is distributed from the main interface to multiple workers via Redis. This setup ensures scalability, responsiveness, and resilience—even under load.

---

## Table of Contents

  - [Why Queue Mode?](#why-queue-mode)
  - [Architecture Overview](#architecture-overview)
  - [Task Processing Flow (Queue Mode)](#task-processing-flow-queue-mode)
  - [What is Queue Mode?](#what-is-queue-mode)
  - [Configuration](#configuration)
  - [Recommended VPS Sizing & Worker Strategy](#recommended-vps-sizing--worker-strategy)
  - [Deployment Commands](#deployment-commands)
  - [Health Checks](#health-checks)
  - [Troubleshooting](#troubleshooting)
    - [Quick Health Checklist](#quick-health-checklist)
    - [Common Issues & Fixes](#common-issues--fixes)
  - [Best Practices, Monitoring, and Scaling](#best-practices-monitoring-and-scaling)
    - [Development Best Practices](#development-best-practices)
    - [Monitor and Scale](#monitor-and-scale)
    - [Scaling Larger Deployments](#scaling-larger-deployments)

##  Why Queue Mode?

- **Scalable Execution**: Offload heavy workflow processing to dedicated worker containers.
- **Responsive UI**: Keep your editor fast and stable regardless of execution load.
- **Reliability**: Workers handle jobs independently—failures won't block the main process.
- **Flexible Deployment**: Horizontally scale workers based on demand.

> Queue Mode works just like orchestration in Kubernetes, batch systems, or load-balanced services.  

---

##  Architecture Overview

<div align="center">

```text
   ┌───────────────────┐
   │   Traefik Proxy   │
   │ (Routes traffic)  │
   └─────────┬─────────┘
             │
             ▼
   ┌───────────────────┐
   │   n8n-Main (UI)   │
   │  - Editor & API   │
   │  - Webhooks       │
   │  - Schedules      │
   └─────────┬─────────┘
             │
             │ Enqueues jobs
             ▼
   ┌───────────────────┐
   │      Redis        │
   │   (BullMQ Queue)  │
   └─────────┬─────────┘
             │
   ┌─────────┴─────────┐
   │                   │
   ▼                   ▼
┌───────────┐     ┌───────────┐
│ Worker #1 │     │ Worker #2 │
└─────┬─────┘     └─────┬─────┘
      │                 │
      └──────┬──────────┘
             │
             ▼
   ┌───────────────────┐
   │   Postgres DB     │
   │ - Workflows       │
   │ - Executions      │
   │ - Credentials     │
   └───────────────────┘
```
</div>

## Task Processing Flow (Queue Mode)
- **Case: 1 Worker**
  - All workflow executions are pulled from **Redis** and processed by a single worker container.
  - Concurrency limits how many executions that worker can run in parallel (e.g., `N8N_WORKER_CONCURRENCY=5`).
  - If the worker is busy or crashes, execution throughput is limited.
```mermaid
sequenceDiagram
    participant U as User
    participant M as n8n Main Service
    participant R as Redis Queue
    participant W as n8n Worker
    participant DB as PostgreSQL Database

    U->>M: Trigger workflow execution
    M->>R: Queue execution task<br/>(EXECUTIONS_MODE=queue)
    R->>DB: Save execution request

    W->>R: Poll for tasks
    R-->>W: Return next task
    W->>DB: Retrieve workflow data
    W->>W: Process workflow
    W->>DB: Save execution results

    U->>M: Request execution status
    M->>DB: Retrieve execution results
    M-->>U: Return execution status
```
- **Case: 2 Workers**
  - Both workers poll Redis at the same time.  
  - Redis distributes tasks between them (first come, first served).  
  - This effectively **doubles the processing capacity** (assuming similar concurrency per worker).  
  - If one worker crashes, the other keeps processing, which improves **resilience**.
```mermaid
sequenceDiagram
    participant U as User
    participant M as n8n Main Service
    participant R as Redis Queue
    participant W1 as Worker #1
    participant W2 as Worker #2
    participant DB as PostgreSQL Database

    U->>M: Trigger workflow execution
    M->>R: Queue execution task (EXECUTIONS_MODE=queue)
    R->>DB: Save execution request

    par Workers poll tasks
        W1->>R: Poll for tasks
        R-->>W1: Return task (if available)
        W1->>DB: Retrieve workflow data
        W1->>W1: Process workflow
        W1->>DB: Save execution results
    and
        W2->>R: Poll for tasks
        R-->>W2: Return task (if available)
        W2->>DB: Retrieve workflow data
        W2->>W2: Process workflow
        W2->>DB: Save execution results
    end

    U->>M: Request execution status
    M->>DB: Retrieve execution results
    M-->>U: Return execution status
```
## What is Queue Mode?

In **single mode**, one n8n container handles **everything** (UI, webhooks, executions). This is fine for small setups, but under load, executions can slow down or block the UI.

**Queue Mode** separates responsibilities:
- **Main (`n8n-main`)** → handles UI, schedules, and webhooks
- **Workers (`n8n-worker`)** → execute workflows (can scale horizontally)
- **Redis** → job queue between main and workers
- **Postgres** → database for workflows, execution history, and credentials

Benefits:
- 🚀 Horizontal scaling → add workers for more throughput
- 🛡️ Isolated workloads → UI stays responsive even under heavy execution load
- ⚙️ Configurable concurrency → fine-tune how many workflows each worker runs in parallel

---

## Configuration

This setup requires two key files:

- [`.env`](./.env) → Environment variables (domain, credentials, queue settings, Postgres, Redis, etc.)  
- [`docker-compose.yml`](./docker-compose.yml) → Defines services: Traefik, Postgres, Redis, n8n-main, and workers

> 💡 Make sure to replace placeholder values (like `DOMAIN`, `SSL_EMAIL`, `STRONG_PASSWORD`, `N8N_ENCRYPTION_KEY`) with your own before deployment.

## Recommended VPS Sizing & Worker Strategy

| VPS (vCPU / RAM) | Setup Suggestion                   |
|------------------|------------------------------------|
| **1 vCPU / 2 GB**  | 1 worker @ concurrency **3–5**      |
| **2 vCPU / 4 GB**  | 1–2 workers @ concurrency **5**     |
| **4 vCPU / 8 GB**  | 2 workers @ concurrency **8**       |
| **8+ vCPU / 16+ GB** | 3–4 workers @ concurrency **8–10** |

## Deployment Commands

Follow these steps to deploy n8n in **Queue Mode** (Main + Redis + Workers).

---

### 1) Generate strong password and N8N_ENCRYPTION_KEY
Generate and set strong secrets:

```bash
openssl rand -base64 16  # STRONG_PASSWORD
openssl rand -base64 32  # N8N_ENCRYPTION_KEY
```

### 2) Update values in `.env`
  ```env
  DOMAIN=automation.example.com
  SSL_EMAIL=you@example.com
  STRONG_PASSWORD=PASTE_16B       # output of command openssl rand -base64 16 
  N8N_ENCRYPTION_KEY=PASTE_32B    # output of command openssl rand -base64 32, must never change once set
```

### 3) Deploy the stack

```bash
# Validate YAML & env expansion first
docker compose config

# Pull images (optional but recommended)
docker compose pull

# Start everything (Traefik, Postgres, Redis, n8n-main, 1 worker)
docker compose up -d

# Scale to 2 workers
docker compose up -d --scale n8n-worker=2
```

## Health check

Run these commands after deployment to verify everything is working:

### n8n-main (UI / API):
```bash
docker exec -it n8n-main wget --spider -q http://localhost:5678/healthz && echo "n8n-main OK"
```
Should print:
```bash
n8n-main OK
```
### Queue mode confirmation:
```bash
docker exec -it n8n-main printenv | grep EXECUTIONS_MODE
```
Should show:
```bash
EXECUTIONS_MODE=queue
```

### Redis (queue backend)
```bash
docker compose exec redis redis-cli ping
```
Should return:
```nginx
PONG
```
### Postgres (database):

```bash
docker exec -it postgres pg_isready -U n8n
docker compose exec postgres psql -U n8n -d n8n -c "\dt"
```
Should return a list of tables. If empty, that’s fine on first boot — tables will appear after you create workflows.

### Traefik TLS:
```bash
curl -I https://$DOMAIN   # Expect 200/302 and valid certificate
```

### Worker connectivity

```bash
# n8n main (UI, webhooks, scheduler)
docker logs -f n8n-main

# Worker(s)
# when you scale a service with Compose, Docker creates multiple containers with numbered suffixes:
# Worker 1
docker logs -f n8n-worker-1

# Worker 2
docker logs -f n8n-worker-2

# List all worker containers:
docker ps --filter "name=n8n-worker" --format "table {{.Names}}\t{{.Status}}"

# Streams logs from all scaled worker containers in one view (very useful to see load balancing in action).
docker compose logs -f n8n-worker

# Redis & Postgres
docker logs -f redis
docker logs -f postgres
```


## Troubleshooting

Even with Queue Mode properly configured, you may encounter issues.  
This section covers the **most common problems** and how to fix them.

---

### UI is slow or unresponsive
- **Cause**: Workflows running inside the main container instead of workers, or workers not connected.  
- **Fix**:
  1. Confirm queue mode:
     ```bash
     docker exec -it n8n-main printenv | grep EXECUTIONS_MODE
     ```
     Should return `EXECUTIONS_MODE=queue`.
  2. Check worker logs:
     ```bash
     docker compose logs -f n8n-worker
     ```
     Look for: `Connected to Redis`.
  3. If workers are missing → scale up:
     ```bash
     docker compose up -d --scale n8n-worker=2
     ```

---

### Jobs stuck in “Waiting” state
- **Cause**: Workers not pulling jobs from Redis.  
- **Fix**:
  - Check Redis health:
    ```bash
    docker compose exec redis redis-cli ping
    ```
    Should reply: `PONG`.
  - If using Redis password, make sure it matches in `.env` (`QUEUE_BULL_REDIS_PASSWORD`) **and** `docker-compose.yml` (with `--requirepass`).
  - Restart workers:
    ```bash
    docker compose restart n8n-worker
    ```

---

### Database connection errors
- **Cause**: Postgres not healthy, wrong credentials, or insufficient resources.  
- **Fix**:
  1. Verify Postgres is running:
     ```bash
     docker compose exec postgres pg_isready -U n8n
     ```
  2. Test DB access:
     ```bash
     docker compose exec postgres psql -U n8n -d n8n -c "\dt"
     ```
     Should return tables (may be empty if new).
  3. Check `.env` → `DB_POSTGRESDB_USER`, `DB_POSTGRESDB_PASSWORD`, `POSTGRES_USER`, `POSTGRES_PASSWORD` must match.

---

### Redis errors in logs
- **Cause**: Password mismatch or Redis crash.  
- **Fix**:
  - If you enabled `--requirepass` in `docker-compose.yml`, keep `QUEUE_BULL_REDIS_PASSWORD` in `.env`.
  - If you don’t want Redis auth, remove both.  
  - Restart Redis:
    ```bash
    docker compose restart redis
    ```

---

### Workflows stop after running a while
- **Cause**: Worker concurrency too high for VPS resources.  
- **Fix**:
  - Lower concurrency in `.env`:
    ```env
    N8N_WORKER_CONCURRENCY=3
    ```
  - Or add more workers:
    ```bash
    docker compose up -d --scale n8n-worker=3
    ```
  - Rule of thumb: scale **workers** before raising concurrency too high.

---

### Backup/restore issues (credentials missing)
- **Cause**: Missing or changed `N8N_ENCRYPTION_KEY`.  
- **Fix**:
  - Always ensure `.env` contains the same `N8N_ENCRYPTION_KEY` used during install.
  - If lost, old credentials cannot be recovered.

---

### Certificates (SSL) not working
- **Cause**: Traefik can’t validate Let’s Encrypt challenge.  
- **Fix**:
  - Confirm `DOMAIN` in `.env` resolves to your VPS public IP.
  - Check Traefik logs:
    ```bash
    docker logs -f traefik
    ```
  - Port 80/443 must be open on firewall/cloud.

---

## Best Practices, Monitoring, and Scaling

### Best Practices for n8n Development
- Keep workflows modular and avoid unnecessary loops or long-running tasks.
- Test new workflows with **manual executions** before scaling them out to workers.
- Use **environment variables** to store sensitive information instead of hardcoding credentials.
- Regularly prune old execution data (set `EXECUTIONS_DATA_PRUNE=true`) to keep the database lean.
- Always back up:
  - Postgres database (workflow definitions + credentials)
  - `.env` file (especially `N8N_ENCRYPTION_KEY`)
  - Redis data (optional, if you want queue persistence)

---

### Monitor and Scale

It’s important to **monitor your queue mode setup** so it doesn’t bottleneck under load.

- **Server Metrics**
  - Use `htop` or your VPS panel to monitor CPU and memory.
  - Run `docker stats` to check individual container performance.

- **Redis Monitoring**
  - Use `redis-cli info memory` or `redis-cli info stats` to track memory and queue usage.
  - Optionally run **Redis Commander** for a visual UI.

- **Database Monitoring**
  - Keep an eye on Postgres growth.
  - Monitor execution times and failed workflows.

- **Application Monitoring**
  - n8n UI → Settings → Executions shows active and past jobs.
  - For advanced monitoring, integrate **Prometheus + Grafana** to visualize queue size, worker load, and execution times.
    
### Scaling Queue Mode for Larger Deployments

When your workload grows, plan for scaling:

- Run **multiple workers** pointing to the same Redis instance.  
- Use **Redis clustering** or managed Redis (e.g., AWS ElastiCache, Azure Cache) for high availability.  
- Scale **Postgres vertically** (more CPU/RAM) or move to a managed DB service for reliability.  
- Split workflows into **different queues** if you have very different workload types (e.g., critical vs. batch jobs).  
- Automate scaling with **Kubernetes** or **Docker Swarm**, letting the orchestrator add/remove workers dynamically.  
