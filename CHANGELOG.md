# Changelog

Все заметные изменения в роли `kubernetes` фиксируются в этом файле.

Формат ориентирован на Keep a Changelog.

## [1.0.1] - 2026-04-22

### Changed

- Перенесена подготовка `kube-apiserver` auth config в [tasks/components/main.yml](tasks/components/main.yml), чтобы использовать общую настройку компонентов вместо дублирования в сценариях bootstrap и join.
- Отрефакторен [tasks/components/main.yml](tasks/components/main.yml): задачи сгруппированы в block'и по типам работ (`packages`, `haproxy`, `kube-apiserver auth`, `containerd`, `services`, `cli tools`).
- Добавлена переменная `kubernetes_kubectl_user_home` для управления путём пользовательского kubeconfig.
- `kubeadm init`, `join master` и `join worker` сделаны идемпотентнее через проверки существования `admin.conf` и `kubelet.conf`.
- Исправлены права на директории private registry config для `containerd`: `0755` вместо `0644`.
- Поведение `kubernetes_add_worker_node` уточнено: `cordon`, labels и taints применяются только к новым worker нодам в рамках текущего onboarding.
- Добавлена поддержка `kubernetes_node_labels` и `kubernetes_node_taints` в [tasks/enviroment/node-labels.yml](tasks/enviroment/node-labels.yml).
- Добавлен merge существующих и новых taints вместо полного перезаписывания `spec.taints`.

## [1.0.0] - 2026-04-01

### Added

- Добавлен `systemd` override для `haproxy` через `override.conf`.
- Добавлены настройки `kubernetes_haproxy_oom_score_adjust` и `kubernetes_haproxy_restart_sec` в [defaults/main.yml](defaults/main.yml).
- В `haproxy` добавлены настройки `OOMScoreAdjust`, `Restart=on-failure` и `RestartSec`.
- Скрипт [haproxy-state.sh](files/haproxy/haproxy-state.sh) расширен режимами:
  - обычная табличная сводка
  - `--down`
  - `--watch <seconds>`
  - `--json`
- В `haproxy-state.sh` добавлены:
  - summary по backend-серверам
  - расширенные колонки `address`, `sessions`, `weight`, `check`
  - цветной вывод статусов
  - базовые проверки наличия `socat` и stats socket
- Полностью обновлён [README.md](README.md):
  - добавлено описание архитектуры роли
  - добавлены примеры inventory, vars и playbook
  - добавлено описание тегов
  - добавлены примеры использования `haproxy-state`

### Fixed

- Исправлено имя файла `haproxy-state.sh` в роли.
- Исправлена совместимость `haproxy-state.sh` с используемой реализацией `awk`.
- Исправлена опечатка в примере `kubernetes_service_cidr` в [README.md](README.md).
