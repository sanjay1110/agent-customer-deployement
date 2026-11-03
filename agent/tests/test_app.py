import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

from app.agent import LLMError, LLMResponse, MockLLM
from app.config import Settings
from app.main import create_app
from app.secrets import SecretStore, SecretUnavailableError
from app.tools import DynamoTicketStore, KnowledgeBase, MemoryTicketStore, ToolRunner

CLIENT_KEY = "k" * 40


def local_settings(**overrides) -> Settings:
    base = Settings()
    values = {**base.__dict__, "app_env": "local", "llm_provider": "mock", **overrides}
    return Settings(**values)


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setenv("CLIENT_API_KEYS", CLIENT_KEY)
    monkeypatch.setenv("LLM_API_KEY", "unused-in-mock")
    store = MemoryTicketStore()
    app = create_app(local_settings(), ticket_store=store)
    c = TestClient(app)
    c.ticket_store = store
    return c


# ------------------------------------------------------------------ API
def test_health_needs_no_auth(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_ready(client):
    assert client.get("/ready").status_code == 200


def test_chat_requires_api_key(client):
    assert client.post("/v1/chat", json={"message": "hi"}).status_code == 401
    assert client.post("/v1/chat", json={"message": "hi"}, headers={"X-API-Key": "wrong"}).status_code == 401


def test_chat_answers_with_kb_search(client):
    r = client.post("/v1/chat", json={"message": "how do I reset my password"}, headers={"X-API-Key": CLIENT_KEY})
    assert r.status_code == 200
    body = r.json()
    assert body["tool_calls"] == ["search_knowledge_base"]
    assert "password-reset" in body["answer"]
    assert r.headers["x-request-id"] == body["request_id"]


def test_chat_creates_ticket(client):
    r = client.post("/v1/chat", json={"message": "I want a human please"}, headers={"X-API-Key": CLIENT_KEY})
    assert r.json()["tool_calls"] == ["create_support_ticket"]
    assert len(client.ticket_store.items) == 1


def test_input_size_limit(client):
    r = client.post("/v1/chat", json={"message": "x" * 5000}, headers={"X-API-Key": CLIENT_KEY})
    assert r.status_code == 413


def test_llm_failure_returns_502(monkeypatch):
    monkeypatch.setenv("CLIENT_API_KEYS", CLIENT_KEY)

    class Broken:
        def complete(self, messages):
            raise LLMError("APIConnectionError")

    c = TestClient(create_app(local_settings(), llm=Broken(), ticket_store=MemoryTicketStore()))
    r = c.post("/v1/chat", json={"message": "hello"}, headers={"X-API-Key": CLIENT_KEY})
    assert r.status_code == 502
    assert "APIConnectionError" not in r.text  # no internal detail leaks


def test_iteration_limit(monkeypatch):
    monkeypatch.setenv("CLIENT_API_KEYS", CLIENT_KEY)

    class Looping:
        def complete(self, messages):
            return LLMResponse(
                "tool_use",
                [{"type": "tool_use", "id": "t", "name": "search_knowledge_base", "input": {"query": "sync"}}],
            )

    c = TestClient(create_app(local_settings(max_tool_iterations=3), llm=Looping(), ticket_store=MemoryTicketStore()))
    r = c.post("/v1/chat", json={"message": "loop"}, headers={"X-API-Key": CLIENT_KEY})
    assert r.status_code == 200
    assert len(r.json()["tool_calls"]) == 3


# ------------------------------------------------------------------ tools / guardrails
def test_unknown_tool_rejected():
    runner = ToolRunner(KnowledgeBase(), MemoryTicketStore())
    assert "unknown tool" in runner.run("delete_all_data", {})["error"]


def test_ticket_input_validation():
    store = MemoryTicketStore()
    runner = ToolRunner(KnowledgeBase(), store)
    assert "error" in runner.run("create_support_ticket", {"summary": "x", "details": "y", "priority": "urgent!!"})
    assert "error" in runner.run("create_support_ticket", {"summary": "x" * 500, "details": "y", "priority": "low"})
    assert store.items == []


def test_mock_llm_shape():
    resp = MockLLM().complete([{"role": "user", "content": "plans"}])
    assert resp.stop_reason == "tool_use"


# ------------------------------------------------------------------ AWS integrations (moto)
def aws_settings(**kw) -> Settings:
    return local_settings(app_env="aws", llm_api_key_secret_id="llm", client_api_key_secret_id="clients", **kw)


@mock_aws
def test_secret_store_reads_secrets_manager_and_caches():
    sm = boto3.client("secretsmanager", region_name="us-east-1")
    sm.create_secret(Name="llm", SecretString="sk-test")
    sm.create_secret(Name="clients", SecretString=CLIENT_KEY)
    store = SecretStore(aws_settings(), client=sm)
    assert store.llm_api_key() == "sk-test"
    assert store.client_api_keys() == [CLIENT_KEY]
    sm.put_secret_value(SecretId="llm", SecretString="sk-rotated")
    assert store.llm_api_key() == "sk-test"  # served from cache within TTL


@mock_aws
def test_client_key_rotation_overlap_and_revoke():
    sm = boto3.client("secretsmanager", region_name="us-east-1")
    sm.create_secret(Name="llm", SecretString="sk-test")
    sm.create_secret(Name="clients", SecretString=CLIENT_KEY)
    new_key = "n" * 40
    sm.put_secret_value(SecretId="clients", SecretString=new_key)  # old key becomes AWSPREVIOUS
    store = SecretStore(aws_settings(secret_cache_ttl_seconds=0), client=sm)
    assert store.client_api_keys() == [new_key, CLIENT_KEY]  # both accepted during overlap
    versions = sm.list_secret_version_ids(SecretId="clients")["Versions"]
    prev = next(v["VersionId"] for v in versions if "AWSPREVIOUS" in v["VersionStages"])
    sm.update_secret_version_stage(SecretId="clients", VersionStage="AWSPREVIOUS", RemoveFromVersionId=prev)
    assert store.client_api_keys() == [new_key]  # old key revoked


@mock_aws
def test_short_client_keys_rejected():
    sm = boto3.client("secretsmanager", region_name="us-east-1")
    sm.create_secret(Name="llm", SecretString="sk-test")
    sm.create_secret(Name="clients", SecretString="too-short")
    assert SecretStore(aws_settings(), client=sm).client_api_keys() == []


@mock_aws
def test_secret_store_refuses_env_fallback_in_aws(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "should-not-be-used")
    sm = boto3.client("secretsmanager", region_name="us-east-1")
    store = SecretStore(local_settings(app_env="aws", llm_api_key_secret_id="missing"), client=sm)
    with pytest.raises(SecretUnavailableError):
        store.llm_api_key()


@mock_aws
def test_empty_secret_container_reports_not_ready():
    sm = boto3.client("secretsmanager", region_name="us-east-1")
    sm.create_secret(Name="llm")  # created by Terraform, value not yet set
    sm.create_secret(Name="clients")
    assert SecretStore(aws_settings(), client=sm).health_check() is False


@mock_aws
def test_dynamo_ticket_store_put():
    ddb = boto3.client("dynamodb", region_name="us-east-1")
    ddb.create_table(
        TableName="tickets",
        KeySchema=[{"AttributeName": "ticket_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "ticket_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    runner = ToolRunner(KnowledgeBase(), DynamoTicketStore("tickets", "us-east-1", client=ddb))
    out = runner.run("create_support_ticket", {"summary": "sync broken", "details": "d", "priority": "high"})
    item = ddb.get_item(TableName="tickets", Key={"ticket_id": {"S": out["ticket_id"]}})["Item"]
    assert item["priority"]["S"] == "high"
