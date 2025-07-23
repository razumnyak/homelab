# 🏠 Homelab Infrastructure Automation

> **Автоматизированная система развертывания homelab инфраструктуры на базе Kubernetes (K3s)**

## 🎯 Цель проекта

Этот проект создан для автоматизации развертывания полнофункциональной homelab инфраструктуры с минимальными усилиями. Система предоставляет готовое к использованию окружение для:

- 🧪 **Экспериментов и обучения** - изучение Kubernetes, DevOps практик, облачных технологий
- 🚀 **Разработки и тестирования** - среда для pet-проектов и прототипирования
- 🛠️ **Self-hosted решений** - собственные сервисы вместо облачных
- 📚 **Практического изучения** инфраструктурных технологий

## ⚡ Быстрый старт

### Минимальные требования
- Ubuntu Server 22.04/24.04 LTS
- 2+ CPU, 4+ GB RAM, 20+ GB disk

### Установка одной командой
```bash
curl -fsSL https://raw.githubusercontent.com/razumnyak/homelab/main/homelab.sh | bash
```
Или
```bash
curl -fsSL https://mozg.dev/homelab.sh | bash
```

## 🏗️ Что получите после установки

### Master Node
- **K3s** - легковесный Kubernetes кластер
- **Pi-hole** - DNS сервер с блокировкой рекламы + DHCP
- **Traefik** - современный ingress controller 
- **ArgoCD** - GitOps инструмент для CD
- **MetalLB** - load balancer для bare metal

### Готовые сервисы
| Сервис | URL | Назначение |
|--------|-----|------------|
| Pi-hole | http://pihole.local/admin | DNS/DHCP управление |
| Traefik | http://traefik.local | Мониторинг ingress |
| ArgoCD | https://argocd.local | GitOps деплойменты |

## 🌐 Сетевая архитектура

Master node выступает как двухпортовый шлюз между локальной сетью и внешним миром:

```
                    MASTER NODE
                   ┌─────────────┐
Локальная сеть ←───┤ LAN   │ WAN ├───→ Внешний мир
10.0.0.0/24        │10.0.0.1│192.168.1.150│
                   └─────────────┘
         │                           │
         │                           │
   ┌──────▼──────┐            ┌──────▼──────┐
   │ КОММУТАТОР  │            │    ROUTER   │
   │             │            │ 192.168.1.1 │
   └──┬──────────┘            └──────┬──────┘
      │                              │
┌─────┴────────────┐                 │
│ SlaveNode + PC's │            ┌────▼────┐
│                  │            │Internet │
│  10.0.0.51-.250  │            └─────────┘
└──────────────────┘
```

**Сервисы в локальной сети:**
- Pi-hole (10.0.0.2) - DNS/DHCP сервер
- Traefik (10.0.0.3) - Ingress контроллер  
- ArgoCD (10.0.0.4) - GitOps платформа

**Преимущества:**
- Изолированная внутренняя сеть
- Централизованный DNS с блокировкой рекламы
- Единая точка входа для всех сервисов
- Автоматическое управление IP адресами

## 🔧 Настройка

### Автоматическая настройка
Система сама попросит выбрать тип узла и сетевые интерфейсы.

### Настройка без промптов (опционально)
```bash
# Скопировать шаблон конфигурации
cp installer/.env.template ~/homelab/.env

# Отредактировать и добавить пароли
nano ~/homelab/.env

# Запустить установку - промптов не будет
./installer/install.sh
```

### Добавление рабочих узлов
```bash
# На новой машине запустить установщик
curl -fsSL https://raw.githubusercontent.com/razumnyak/homelab/main/homelab.sh | bash

# Выбрать "slave-node"
# Указать IP мастера и токен кластера
```

## 🛡️ Безопасность

- **Никаких хардкод паролей** - все через .env файл
- **Автоматическая синхронизация SSH ключей** с GitHub
- **Firewall настроен** с базовой защитой
- **Изолированная внутренняя сеть**

## 📊 Управление кластером

### Проверка статуса
```bash
kubectl get nodes
kubectl get pods -A
kubectl get svc -A
```

### Деплой приложений
Рекомендуется использовать ArgoCD для GitOps подхода:
1. Создать Git репозиторий с Kubernetes манифестами
2. Добавить его в ArgoCD через веб-интерфейс
3. ArgoCD автоматически синхронизирует изменения

## 📁 Структура проекта

```
homelab/
├── homelab.sh                           # Точка входа - главный скрипт запуска
├── README.md                            # Документация проекта
└── installer/                           # Директория установочных скриптов
    ├── install.sh                       # Главный установщик
    └── scripts/                         # Модули установки
        ├── 00-cloud-init-reset.sh       # Сброс cloud-init конфигурации
        ├── 01-cleanup-existing.sh       # Очистка существующих установок
        ├── 02-environment-setup.sh      # Настройка окружения
        ├── 05-system-prerequisites.sh   # Установка системных зависимостей
        ├── 06-configure-network.sh      # Настройка сетевой конфигурации
        ├── 07-install-k3s-master.sh     # Установка K3s master узла
        ├── 08-install-k3s-agent.sh      # Установка K3s agent узла
        ├── 09-install-metallb.sh        # Установка MetalLB load balancer
        ├── 10-install-pihole.sh         # Установка Pi-hole DNS/DHCP
        ├── 11-install-traefik.sh        # Установка Traefik ingress controller
        ├── 12-install-argocd.sh         # Установка ArgoCD GitOps
        ├── 13-configure-routing.sh      # Настройка маршрутизации
        ├── 14-setup-cron-jobs.sh        # Настройка cron заданий
        ├── 99-post-install-check.sh     # Финальная проверка установки
        ├── common-functions.sh          # Общие функции для скриптов
        ├── smart-ssh-key-updater.sh     # Умное обновление SSH ключей
        ├── ssh-key-manager.sh           # Управление SSH ключами
        └── update-nodes-list.sh         # Обновление списка узлов кластера
```

## 🐛 Диагностика

### Логи установки
```bash
cat ~/homelab/logs/install-*.log
```

### Проверка сервисов
```bash
systemctl status k3s          # на master
systemctl status k3s-agent    # на slave
```

### Проверка сети
```bash
kubectl get svc -A
nslookup google.com 10.0.0.2  # тест Pi-hole DNS
```

## 🤝 Участие в разработке

1. Fork репозитория  
2. Внесение изменений
3. Pull Request

## 📝 Лицензия

MIT License - используйте свободно для личных и коммерческих проектов.

## 🙏 Благодарности

Проект использует следующие открытые технологии:
- [K3s](https://k3s.io/) - Lightweight Kubernetes
- [MetalLB](https://metallb.io/) - Load Balancer для bare metal
- [Pi-hole](https://pi-hole.net/) - Network-wide Ad Blocking
- [Traefik](https://traefik.io/) - Modern HTTP Reverse Proxy
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps Continuous delivery

---

**⭐ Если проект помог - поставьте звездочку!**