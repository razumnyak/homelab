# 🏠 Homelab Bootstrap Infrastructure

> **Bootstrap установка критической инфраструктуры Kubernetes кластера**

## 🎯 Назначение

Bootstrap установка критической инфраструктуры Kubernetes кластера:
- K3s кластер
- ArgoCD для GitOps
- Базовая сетевая конфигурация

## Что НЕ включено
- Pi-hole (управляется ArgoCD)
- Traefik (управляется ArgoCD)
- Приложения (управляются ArgoCD)

## ⚡ Быстрый старт

### Минимальные требования
- Ubuntu Server 22.04/24.04 LTS
- 2+ CPU, 4+ GB RAM, 20+ GB disk

### Установка одной командой
```bash
curl -fsSL https://mozg.dev/homelab.sh | bash
```

После установки bootstrap инфраструктуры, ArgoCD автоматически развернет остальные сервисы из homelab-k8s репозитория.

## 🏗️ Что получите после установки

### Bootstrap компоненты
- **K3s** - легковесный Kubernetes кластер
- **ArgoCD** - GitOps инструмент для CD
- **Базовая сетевая конфигурация**

### Управляемые ArgoCD сервисы
| Сервис | Тип доступа | Назначение |
|--------|-------------|------------|
| Pi-hole | hostNetwork | DNS/DHCP сервер |
| Traefik | hostNetwork | Ingress контроллер |
| Приложения | ClusterIP | Пользовательские сервисы |

## 🌐 Архитектура доступа

### Bootstrap фаза:
```
External Client
      ↓
Master Node WAN IP (192.168.1.150)
      ↓ kubectl port-forward
ArgoCD Pod (ClusterIP)
```

### После развертывания ArgoCD:
```
External Client
      ↓ HTTP/HTTPS
Master Node WAN IP (192.168.1.150:80/443)
      ↓ hostNetwork
Traefik Pod
      ↓ Kubernetes DNS
pihole.pihole.svc.cluster.local
      ↓
Pi-hole Pod (ClusterIP)
```

### Сетевая топология:
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

**Ключевые принципы:**
- **hostNetwork** для внешнего доступа (Traefik, Pi-hole DHCP/DNS)
- **ClusterIP** для внутренних сервисов (ArgoCD, приложения)
- **Kubernetes DNS** для service discovery
- **Нет LoadBalancer** - упрощенная архитектура

**Преимущества:**
- Минимальная bootstrap конфигурация
- Стандартный Kubernetes без дополнительных компонентов
- Автоматический service discovery через DNS
- GitOps управление всеми сервисами

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
- **ClusterIP изоляция** - внутренние сервисы недоступны извне
- **hostNetwork только для необходимых сервисов**

## 📊 Управление кластером

### Проверка статуса
```bash
kubectl get nodes
kubectl get pods -A
kubectl get svc -A
```

### Деплой приложений
ArgoCD автоматически развертывает приложения из homelab-k8s репозитория:
1. Bootstrap устанавливает ArgoCD с настроенным App-of-Apps
2. ArgoCD подключается к homelab-k8s репозиторию
3. Все изменения в homelab-k8s автоматически применяются

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
        ├── 12-install-argocd.sh         # Установка ArgoCD GitOps
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

### Доступ к ArgoCD
```bash
# Временный доступ в bootstrap фазе
kubectl port-forward -n argocd svc/argocd-server 8080:80
# Затем: http://localhost:8080

# После развертывания Traefik
# https://argocd.local
```

### Проверка сервисов
```bash
kubectl get svc -A
kubectl get pods -A
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
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps Continuous delivery
- [Pi-hole](https://pi-hole.net/) - Network-wide Ad Blocking (управляется ArgoCD)
- [Traefik](https://traefik.io/) - Modern HTTP Reverse Proxy (управляется ArgoCD)

---

**⭐ Если проект помог - поставьте звездочку!**