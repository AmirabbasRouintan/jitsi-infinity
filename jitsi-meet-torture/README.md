# Jitsi Meet Torture - Load Testing

Load testing infrastructure for Jitsi Meet using [jitsi-meet-torture](https://github.com/jitsi/jitsi-meet-torture) with Selenium Grid.

## Quick Start

### 1. Clone the torture repo
```bash
git clone https://github.com/jitsi/jitsi-meet-torture.git
cd jitsi-meet-torture
```

### 2. Start the Selenium Grid
```bash
# From the project root (jitsi-infinity)
docker compose -f jitsi-meet-torture.yml up -d --scale chrome-node=4
```

This starts:
- 1 Selenium Hub (port 4444)
- 4 Chrome nodes (each runs one browser)

### 3. Run a load test
```bash
# From the jitsi-meet-torture directory
./scripts/malleus.sh \
  --conferences=1 \
  --participants=4 \
  --senders=2 \
  --audio-senders=2 \
  --duration=60 \
  --hub-url=http://localhost:4444/wd/hub \
  --instance-url=https://185.206.92.19:8443/testroom
```

### 4. Stop the grid
```bash
docker compose -f jitsi-meet-torture.yml down
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SELENIUM_VERSION` | `4.27` | Selenium Grid version |
| `SELENIUM_HUB_PORT` | `4444` | Hub port |
| `CHROME_SHM_SIZE` | `2gb` | Shared memory per Chrome node |
| `SE_NODE_MAX_SESSIONS` | `1` | Max sessions per node |
| `SE_NODE_SESSION_TIMEOUT` | `120` | Session timeout in seconds |

## Scaling

To add more participants, scale the Chrome nodes:

```bash
docker compose -f jitsi-meet-torture.yml up -d --scale chrome-node=10
```

Each node = 1 browser = 1 participant. Make sure your server has enough CPU/RAM.

## Parameters

| Parameter | Description |
|-----------|-------------|
| `--conferences=1` | Number of rooms (use 1 for testing a specific room) |
| `--participants=N` | Total participants to join |
| `--senders=N` | How many send video |
| `--audio-senders=N` | How many send audio |
| `--duration=N` | Test duration in seconds |
| `--hub-url=URL` | Selenium Hub URL |
| `--instance-url=URL` | Your Jitsi Meet room URL |
