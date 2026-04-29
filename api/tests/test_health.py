from __future__ import annotations

import pytest


class TestHealth:
    def test_health_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200

    def test_health_response_shape(self, client):
        resp = client.get("/health")
        body = resp.json()
        assert body["status"] == "ok"
        assert body["version"] == "0.1.0"
        assert "deployment" in body

    def test_health_deployment_default(self, client):
        resp = client.get("/health")
        body = resp.json()
        assert body["deployment"] == "lan"


class TestStubRouters:
    def test_observations_ping_returns_501(self, client):
        resp = client.get("/api/v1/observations/ping")
        assert resp.status_code == 501

    def test_search_ping_returns_501(self, client):
        resp = client.get("/api/v1/search/ping")
        assert resp.status_code == 501

    def test_mcp_ping_returns_501(self, client):
        resp = client.get("/mcp/ping")
        assert resp.status_code == 501
