# GitOps Workflow

## Архитектура

### 1. homelab-installer (этот репозиторий)
Bootstrap кластера и критической инфраструктуры:
- K3s Kubernetes кластер
- ArgoCD для GitOps
- MetalLB load balancer
- Базовая сетевая конфигурация

### 2. homelab-k8s (отдельный репозиторий)
Приложения управляемые ArgoCD:
- Pi-hole (DNS/DHCP)
- Traefik (Ingress Controller)
- Пользовательские приложения
- Мониторинг и логирование

## Развертывание

### Шаг 1: Bootstrap установка
```bash
curl -fsSL https://mozg.dev/homelab.sh | bash
```

### Шаг 2: Автоматическое развертывание
1. ArgoCD устанавливается с настроенным App-of-Apps
2. ArgoCD автоматически подключается к homelab-k8s репозиторию
3. Все приложения развертываются через GitOps

### Шаг 3: Управление изменениями
- Изменения в homelab-k8s → автоматическое развертывание
- Мониторинг: ArgoCD UI https://argocd.local

## Управление приложениями

### Структура homelab-k8s репозитория
```
homelab-k8s/
├── infrastructure/           # App-of-Apps конфигурация
│   ├── app-of-apps.yaml
│   └── projects/
├── applications/
│   ├── pihole/
│   ├── traefik/
│   ├── monitoring/
│   └── custom-apps/
└── overlays/                # Environment-specific configs
    ├── production/
    └── staging/
```

### Добавление нового приложения
1. Создать манифесты в `applications/new-app/`
2. Добавить Application в `infrastructure/`
3. Commit и push → автоматическое развертывание

### Обновление приложения
1. Изменить манифесты в homelab-k8s
2. Commit и push
3. ArgoCD автоматически синхронизирует изменения

## Мониторинг

### ArgoCD UI
- URL: https://argocd.local
- Статус всех приложений
- История синхронизации
- Rollback возможности

### CLI команды
```bash
# Проверка статуса приложений
kubectl get applications -n argocd

# Мониторинг подов
kubectl get pods -A

# Логи ArgoCD
kubectl logs -n argocd -f deployment/argocd-application-controller
```

## Преимущества

1. **Декларативное управление** - инфраструктура как код
2. **Автоматическая синхронизация** - изменения применяются автоматически
3. **История изменений** - Git как источник истины
4. **Rollback** - простой откат к предыдущим версиям
5. **Масштабируемость** - легко добавлять новые приложения

## Troubleshooting

### ArgoCD не синхронизирует
```bash
# Проверить статус App-of-Apps
kubectl get application homelab-infrastructure -n argocd

# Принудительная синхронизация
kubectl patch application homelab-infrastructure -n argocd --type merge -p='{"operation": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}'
```

### Приложение в статусе OutOfSync
1. Проверить логи ArgoCD
2. Проверить валидность манифестов
3. Проверить доступность репозитория
4. Выполнить ручную синхронизацию через UI