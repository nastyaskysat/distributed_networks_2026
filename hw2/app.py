"""HW2: simple three-tier HTTP service without third-party libraries."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import psycopg


class DomainError(Exception):
    """Expected business error which should be returned to a client."""

    def __init__(self, message: str, status: HTTPStatus = HTTPStatus.CONFLICT):
        super().__init__(message)
        self.status = status


class NumberRepository:
    """Database layer. PostgreSQL stores accepted numbers permanently."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._create_schema()

    def _connect(self) -> psycopg.Connection:
        return psycopg.connect(self.database_url)

    def _create_schema(self) -> None:
        with self._connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "CREATE TABLE IF NOT EXISTS processed_numbers ("
                    "number INTEGER PRIMARY KEY)"
                )
                cursor.execute(
                    "CREATE TABLE IF NOT EXISTS service_state ("
                    "name TEXT PRIMARY KEY, value INTEGER NOT NULL)"
                )

    def process(self, number: int) -> tuple[bool, str | None]:
        """Atomically validate and save a number. False means a business error."""
        with self._connect() as connection:
            with connection.cursor() as cursor:
                # One short database lock keeps concurrent HTTP requests ordered.
                cursor.execute("SELECT pg_advisory_xact_lock(42)")
                cursor.execute(
                    "SELECT value FROM service_state WHERE name = 'last_processed'"
                )
                row = cursor.fetchone()
                if row is not None and number == row[0] - 1:
                    return False, (
                        f"number {number} is one less than the last processed "
                        f"number {row[0]}"
                    )

                cursor.execute(
                    "SELECT 1 FROM processed_numbers WHERE number = %s", (number,)
                )
                if cursor.fetchone() is not None:
                    return False, f"number {number} has already been processed"

                cursor.execute(
                    "INSERT INTO processed_numbers(number) VALUES (%s)", (number,)
                )
                cursor.execute(
                    "INSERT INTO service_state(name, value) VALUES ('last_processed', %s) "
                    "ON CONFLICT(name) DO UPDATE SET value = EXCLUDED.value",
                    (number,),
                )
        return True, None


@dataclass
class IncrementService:
    """Application layer: validation and the rules from the assignment."""

    repository: Any
    max_number: int

    def increment(self, number: Any) -> int:
        if isinstance(number, bool) or not isinstance(number, int):
            raise DomainError("number must be an integer", HTTPStatus.BAD_REQUEST)
        if not 0 <= number <= self.max_number:
            raise DomainError(
                f"number must be between 0 and {self.max_number}", HTTPStatus.BAD_REQUEST
            )

        accepted, message = self.repository.process(number)
        if not accepted:
            assert message is not None
            print(f"ERROR: {message}")
            raise DomainError(message)
        return number + 1


class IncrementRequestHandler(BaseHTTPRequestHandler):
    """Web-server layer: HTTP details only; rules stay in IncrementService."""

    service: IncrementService

    def do_POST(self) -> None:  # noqa: N802 - this name is required by Python
        if self.path != "/increment":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "route not found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(content_length))
            if not isinstance(data, dict) or "number" not in data:
                raise DomainError("JSON object with field 'number' is required", HTTPStatus.BAD_REQUEST)
            result = self.service.increment(data["number"])
            self._send_json(HTTPStatus.OK, {"result": result})
        except json.JSONDecodeError:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON"})
        except DomainError as error:
            self._send_json(error.status, {"error": str(error)})

    def _send_json(self, status: HTTPStatus, body: dict[str, Any]) -> None:
        encoded = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format: str, *_args: object) -> None:
        """Do not duplicate normal HTTP messages in the terminal."""


def build_service(database_url: str, max_number: int) -> IncrementService:
    return IncrementService(NumberRepository(database_url), max_number)


def main() -> None:
    max_number = int(os.getenv("MAX_NUMBER", "1000000"))
    database_url = os.getenv(
        "DATABASE_URL", "postgresql://hw2:hw2@127.0.0.1:5432/hw2"
    )
    IncrementRequestHandler.service = build_service(database_url, max_number)
    server = ThreadingHTTPServer(("127.0.0.1", 8000), IncrementRequestHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
