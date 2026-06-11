#!/usr/bin/env python3
"""
Jibri Auto-scaler v2

Polls jicofo's REST API (/stats) to track jibri availability and scales
the jibri container pool accordingly:
  - Always keeps at least AUTOSCALER_MIN_IDLE jibris available (idle)
  - When all available jibris are busy -> starts stopped jibri containers
  - When excess jibris are idle too long -> stops them (sleep)

No XMPP dependency — just HTTP + Docker API.
"""

import json
import logging
import os
import sys
import time
from typing import Optional, Set

import docker
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("jibri-autoscaler")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
JICOFO_URL = os.environ.get("JICOFO_URL", "http://jicofo:8888/stats")
POLL_INTERVAL = int(os.environ.get("AUTOSCALER_POLL_INTERVAL", "15"))
MIN_IDLE = int(os.environ.get("AUTOSCALER_MIN_IDLE", "1"))
MAX_TOTAL = int(os.environ.get("AUTOSCALER_MAX_TOTAL", "20"))
IDLE_TIMEOUT = int(os.environ.get("AUTOSCALER_IDLE_TIMEOUT", "300"))
CONTAINER_PREFIX = os.environ.get("AUTOSCALER_CONTAINER_PREFIX", "jitsi-jibri-")

# ---------------------------------------------------------------------------
# Docker Manager
# ---------------------------------------------------------------------------
class DockerManager:

    def __init__(self):
        self.client = docker.from_env()
        self.all_names: Set[str] = {
            f"{CONTAINER_PREFIX}{i}" for i in range(1, MAX_TOTAL + 1)
        }

    def running(self) -> Set[str]:
        containers = self.client.containers.list(filters={"name": CONTAINER_PREFIX})
        names = {c.name for c in containers}
        return names & self.all_names

    def start(self, name: str) -> bool:
        try:
            c = self.client.containers.get(name)
            if c.status != "running":
                c.start()
                log.info("Started: %s", name)
                return True
            else:
                log.debug("Container already running: %s", name)
                return True
        except docker.errors.NotFound:
            log.warning("Container %s not found, cannot start", name)
            return False
        except Exception as e:
            log.error("Failed to start %s: %s", name, e)
            return False

    def stop(self, name: str):
        try:
            c = self.client.containers.get(name)
            if c.status == "running":
                c.stop()
                log.info("Stopped: %s", name)
            else:
                log.debug("Already stopped: %s", name)
        except docker.errors.NotFound:
            log.warning("Container %s not found, skipping stop", name)
        except Exception as e:
            log.error("Failed to stop %s: %s", name, e)


# ---------------------------------------------------------------------------
# Jicofo Stats
# ---------------------------------------------------------------------------
def fetch_jibri_stats() -> Optional[dict]:
    try:
        resp = requests.get(JICOFO_URL, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        jd = data.get("jibri_detector", {})
        return {
            "total": jd.get("count", 0),
            "available": jd.get("available", 0),
        }
    except Exception as e:
        log.error("Failed to fetch jicofo stats: %s", e)
        return None


# ---------------------------------------------------------------------------
# Main Loop
# ---------------------------------------------------------------------------
def main():
    docker_mgr = DockerManager()

    # Track which containers we started and when (for scale-down ordering)
    last_started: dict[str, float] = {}
    last_available_count = 0

    log.info(
        "Autoscaler started: min_idle=%d  max_total=%d  idle_timeout=%ds  interval=%ds",
        MIN_IDLE, MAX_TOTAL, IDLE_TIMEOUT, POLL_INTERVAL,
    )

    while True:
        time.sleep(POLL_INTERVAL)

        try:
            stats = fetch_jibri_stats()
            if stats is None:
                continue

            available = stats["available"]
            total_muc = stats["total"]
            running = docker_mgr.running()
            running_count = len(running)

            log.info(
                "State: %d available / %d in MUC  |  %d/%d containers running",
                available, total_muc, running_count, len(docker_mgr.all_names),
            )

            # -- Initial boot: nothing running at all --
            if running_count == 0:
                target = min(MIN_IDLE + 1, MAX_TOTAL)
                log.info("Initial boot: starting %d jibris", target)
                for i in range(target):
                    name = f"{CONTAINER_PREFIX}{i + 1}"
                    if docker_mgr.start(name):
                        last_started[name] = time.time()
                continue

            # -- Scale up: not enough available --
            if available < MIN_IDLE and running_count < MAX_TOTAL:
                stopped = sorted(docker_mgr.all_names - running)
                if stopped:
                    name = stopped[0]
                    log.info(
                        "Scale UP: available=%d < min_idle=%d -> starting %s",
                        available, MIN_IDLE, name,
                    )
                    if docker_mgr.start(name):
                        last_started[name] = time.time()
                    continue

            # -- Scale down: too many available for too long --
            # If available > MIN_IDLE, we have extras. Find the most recently
            # started container (that jicofo knows about) and stop it.
            # But wait for IDLE_TIMEOUT before scaling down.
            excess = available - MIN_IDLE
            if excess > 0 and running_count > MIN_IDLE:
                # Find candidate: running container that's NOT among the
                # first MIN_IDLE containers (keep 1..MIN_IDLE hot always).
                # The "excess" containers are the highest-numbered ones.
                candidates = sorted(running - {f"{CONTAINER_PREFIX}{i}" for i in range(1, MIN_IDLE + 1)})
                if candidates:
                    name = candidates[-1]  # highest-numbered
                    started_at = last_started.get(name)
                    now = time.time()
                    if started_at and (now - started_at) > IDLE_TIMEOUT:
                        log.info(
                            "Scale DOWN: %d excess, %s idle for %.0fs -> stopping %s",
                            excess, name, now - started_at, name,
                        )
                        docker_mgr.stop(name)
                        last_started.pop(name, None)
                        continue
                    elif not started_at:
                        # Container was already running before autoscaler started
                        # Assume it's been idle long enough
                        log.info(
                            "Scale DOWN: %d excess, stopping %s (no start time)",
                            excess, name,
                        )
                        docker_mgr.stop(name)
                        continue

            # Track when available count changes (for diagnostics)
            if available != last_available_count:
                log.debug("Available changed: %d -> %d", last_available_count, available)
                last_available_count = available

        except Exception as e:
            log.error("Decision error: %s", e, exc_info=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.info("Shutting down")
