# make build     — собрать dist/vless-setup.sh из src/
# make lint      — shellcheck по собранным скриптам
# make test      — сквозные тесты мастера на имитации серверов (нужен root: запускайте в контейнере или CI)
# make validate  — проверить все варианты конфигов настоящим Xray: make validate XRAY_DIR=/путь/к/xray
# make clean     — удалить dist/

.PHONY: all build lint test validate clean

all: build lint

build:
	python3 tools/build.py

lint: build
	shellcheck dist/*.sh tests/*.sh
	python3 -m py_compile src/lib/panel.py tools/build.py

test: build
	bash tests/e2e.sh

validate: build
	bash tests/validate-configs.sh

clean:
	rm -rf dist src/lib/__pycache__ tools/__pycache__
