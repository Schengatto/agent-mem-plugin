from __future__ import annotations


class TestHealth:
    def test_health_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200

    def test_health_response_shape(self, client):
        from app.main import app

        resp = client.get("/health")
        body = resp.json()
        assert body["status"] == "ok"
        assert body["version"] == app.version
        assert "deployment" in body

    def test_health_deployment_default(self, client):
        resp = client.get("/health")
        body = resp.json()
        assert body["deployment"] == "lan"


class TestStubRouters:
    def test_observations_ping_returns_501(self, client):
        assert client.get("/api/v1/observations/ping").status_code == 501

    def test_search_ping_returns_501(self, client):
        assert client.get("/api/v1/search/ping").status_code == 501

    def test_manifest_ping_returns_501(self, client):
        assert client.get("/api/v1/manifest/ping").status_code == 501

    def test_vocab_ping_returns_501(self, client):
        assert client.get("/api/v1/vocab/ping").status_code == 501

    def test_sessions_ping_returns_501(self, client):
        assert client.get("/api/v1/sessions/ping").status_code == 501

    def test_mcp_ping_returns_501(self, client):
        assert client.get("/mcp/ping").status_code == 501
