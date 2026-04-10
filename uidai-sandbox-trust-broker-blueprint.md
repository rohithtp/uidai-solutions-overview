# Blueprint: UIDAI Sandbox Trust Broker Project Structure

This document serves as the architectural blueprint for the `uidai-sandbox-trust-broker` project. It outlines the current organization and provides a roadmap for future expansion.

## 1. High-Level Architecture

The project follows a **Microservices Architectural Pattern** within a **Maven Multi-Module** repository. This setup allows for code sharing via internal libraries while maintaining independent deployability for the core services.

### Core Modules
- **`interoperability-gateway-service`**: The entry point for external systems. Handles protocol transformation, request routing, and event publishing to Kafka for audit/telemetry.
- **`token-verification-and-translation-service`**: The security hub. Responsible for validating JWTs/tokens, translating them into formats compatible with UIDAI, and consuming verification requests via messaging.

### Shared & Messaging Modules
To ensure decoupling and consistency, the following areas are defined:
- **`trust-broker-common`**: Shared models (DTOs), custom exceptions, utility classes, and common security configurations.
- **`messaging` (Kafka Integration)**: Centralized definition of Kafka topics, schemas (Avro/JSON), and shared Producer/Consumer configurations to ensure reliable event flow between services.
- **`trust-broker-sdk` (Optional/Future)**: A client library for other UIDAI services. While valuable for scaling integration, it is considered a secondary objective for the current assignment.

---

## 2. Standardized Package Structure

Each service module should follow a consistent package layout:

| Package | Responsibility |
|---|---|
| `.config` | Spring Configuration (Security, Kafka, Redis, Bean definitions). |
| `.controller` | REST Controllers following OpenAPI/REST standards. |
| `.service` | Business logic layer. Includes Token translation and Kafka producers/consumers. |
| `.messaging` | Service-specific Messaging logic (Consumers/Producers). |
| `.model.dto` | Data Transfer Objects for API requests and response schemas. |
| `.exception` | Service-specific exception classes and `GlobalExceptionHandler`. |
| `.client` | Feign or RestTemplate clients for synchronous calls. |

---

## 3. Infrastructure and Tooling

The infrastructure focuses on high-performance caching and event-driven decoupling.

### Directory Layout
```text
uidai-sandbox-trust-broker/
├── .github/                   # CI/CD Workflows
├── docker/                    # Orchestration
│   ├── kafka/                 # Kafka & Zookeeper configuration
│   └── redis/                 # Redis config (for JWKS/Token caching)
├── docs/                      # Architectural ADRs and API Specs
├── interoperability-gateway-service/
├── token-verification-and-translation-service/
├── trust-broker-common/       # Shared Library
├── scripts/                   # Deployment/Dev helper scripts
├── pom.xml                    # Parent POM
└── README.md                  # Project Hub
```

### Key Infrastructure Components
- **Kafka**: Acts as the backbone for asynchronous event flow and audit logging between the Gateway and Verification services.
- **Redis**: Primary caching layer for JWKS (JSON Web Key Sets) and frequently translated tokens to minimize latency.

---

## 4. Design Standards

1. **API First**: Use OpenAPI (Swagger) to document all endpoints. APIs must be designed and documented before or alongside implementation to ensure consistent integration.
2. **Event-Driven Architecture**: Use Kafka for non-blocking communication where immediate response is not required.
3. **JWKS Caching**: Optimize security overhead by caching external provider keys in Redis.
4. **Statelessness**: Services must remain stateless for horizontal scalability.
5. **Structured Logging**: JSON-formatted logs for seamless aggregation.

---

## 5. Implementation Roadmap

1. **Phase 1 (Complete)**: Baseline services with health checks and basic REST controllers.
2. **Phase 2 (In-Progress)**: Establishment of `trust-broker-common` and shared DTO normalization.
3. **Phase 3 (Next)**: Integration of Kafka for event flow and Redis for JWKS caching.
4. **Phase 4**: Implementation of the **Centralized Authentication Broker** logic—routing all inter-system requests through the Token Verification service to establish the "Trust Broker" layer.

