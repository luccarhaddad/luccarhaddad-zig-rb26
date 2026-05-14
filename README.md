# luccarhaddad-zig — Rinha de Backend 2026

Backend em Zig para a [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026).

## Stack

- **[Zig](https://ziglang.org/)** — servidor HTTP com KNN para busca vetorial
- **Nginx** — load balancer (2 instâncias da aplicação)

## Arquitetura

```
                 ┌─────────────────┐
                 │   nginx :9999   │
                 └────────┬────────┘
               ┌──────────┴──────────┐
          ┌────▼────┐           ┌────▼────┐
          │  app1   │           │  app2   │
          │ :8080   │           │ :8080   │
          └─────────┘           └─────────┘
```

## Limites de recursos (docker-compose)

| Serviço | CPU  | Memória |
|---------|------|---------|
| app1    | 0.40 | 120 MB  |
| app2    | 0.40 | 120 MB  |
| nginx   | 0.20 | 110 MB  |

## Rodar localmente

```bash
docker compose up
```

A API fica disponível em `http://localhost:9999`.

## Docker

```
docker pull luccarhaddad/rinha-2026-zig:v1
```
