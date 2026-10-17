db-up:
	docker compose up -d --wait db

db-down:
	docker compose down

install:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt

run:
	.venv/bin/python app.py

