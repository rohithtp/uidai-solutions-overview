# UIDAI Sandbox Trust Broker — Interview Walkthrough

> **How to use this document:** Read each phase out loud as a narrative. Each section maps to a real git commit and tells the story of *what* was built, *why* it was designed that way, and *how* it was validated.

---

## 1. The Problem Statement

> *"What did you actually build, and why?"*

I built a **Trust Broker** — a middleware system that sits between external consumer systems (banks, healthcare apps, etc.) and UIDAI's identity token infrastructure.

The core problem: external systems speak different protocols, have different trust levels, and should not be allowed to directly call UIDAI's verification APIs. The Trust Broker acts as a **secure, policy-enforced gateway** that:

1. **Validates** whether a calling system is even allowed to make a request (system registry + trust level check)
2. **Routes** the request asynchronously via the appropriate channel (Kafka)
3. **Verifies** the incoming JWT token using a cryptographically trusted JWKS
4. **Translates** it into a normalized, re-signed Sandbox Session Token with enriched claims

The project is a **Spring Boot multi-module Maven monorepo** with 3 modules:

| Module | Port | Role |
|---|---|---|
| `trust-broker-common` | — | Shared DTOs, Kafka topic config, exception handlers |
| `interoperability-gateway-service` | 8081 | API gateway, system registry, routing |
| `token-verification-and-translation-service` | 8082 | JWT verification, token re-signing |

---

## 2. Phase 1 — Scaffolding the Foundation
**Commit:** `9d90aea` — *Initial commit: Set up UIDAI Sandbox Trust Broker multi-module project*

### What I built

The project starts with a carefully designed multi-module Maven layout. I didn't just create three Spring Boot apps — I made them siblings under a **parent POM** so that dependency versions are managed centrally.

```
pom.xml (parent)
├── trust-broker-common/      ← shared library (no main class)
├── interoperability-gateway-service/
└── token-verification-and-translation-service/
```

The `trust-broker-common` module defines the **shared contract** for both services:
- `TokenRequest` / `TokenResponse` — the canonical DTO passed across the entire system
- `AuditEvent` — a structured event for future audit trails
- `KafkaTopicConfig` — single source of truth for topic names (`trust-broker.token.verification`)
- `GlobalExceptionHandler` — centralized error handling via `@ControllerAdvice`
- `OpenApiConfig` — Swagger/OpenAPI documentation setup

### Why this structure

I chose a monorepo with a parent POM over separate repos for these reasons:
- **Shared DTOs without publishing artifacts**: Both services use the same `TokenRequest`/`TokenResponse` without a separate Maven artifact publish step.
- **Version pinning**: All Spring Boot, Kafka, Nimbus JOSE, and Lombok versions are defined once in the parent.
- **Atomic commits**: A contract change (e.g., adding a field to `TokenRequest`) and the corresponding service changes happen in one commit.

### Testing at this stage

Even before any real business logic, I set up **controller-layer smoke tests**:
- `GatewayControllerTest` — validates that the `POST /api/v1/gateway/process` endpoint wires up correctly
- `TokenControllerTest` — validates the `POST /api/v1/token/verify` endpoint

These use `@WebMvcTest` so they load only the web layer (no Kafka, no Redis) and run fast.

---

## 3. Phase 2 — Service Layer Implementation
**Commit:** `e5ed4c8` — *feat: implement service layers for gateway and token services, and update tests*

### What I built

This commit introduces the **interface + implementation** pattern for both services.

**Gateway Service:**
```java
// GatewayService.java — the contract
TokenResponse processIncomingRequest(TokenRequest request);

// GatewayServiceImpl.java — the first pass
// Validates request, calls Kafka producer (stubbed), returns ACCEPTED
```

**Token Service:**
```java
// TokenService.java — the contract
TokenResponse verifyAndTranslate(TokenRequest request);

// TokenServiceImpl.java — first pass
// Placeholder verification, returns VERIFIED
```

### Why interfaces

I always define services as interfaces first. This allows:
- **Mocking in tests**: `@MockBean GatewayService` in `GatewayControllerTest` — the test never instantiates the real implementation
- **Future swap**: If routing needs to change from Kafka to HTTP, only the `impl` changes; the controller is untouched
- **Compile-time contract checking**: Any method added to the interface immediately flags a compile error in the impl

### Testing at this stage

I updated the `GatewayControllerTest` to use Mockito's `when(...).thenReturn(...)` pattern:
```java
when(gatewayService.processIncomingRequest(any())).thenReturn(
    TokenResponse.builder().status("ACCEPTED").message("Request received").build()
);
mockMvc.perform(post("/api/v1/gateway/process")...)
    .andExpect(jsonPath("$.status").value("ACCEPTED"));
```

This verified the controller correctly delegates to the service and serializes the response as JSON.

---

## 4. Phase 3 — Asynchronous Kafka Messaging
**Commit:** `87f92f8` — *feat: integrate Kafka messaging for asynchronous request processing*

### What I built

This is where the **async decoupling** between the two services is established.

**Producer side (Gateway):**
```java
// KafkaProducerServiceImpl.java
kafkaTemplate.send(topic, request.getSystemId(), request)
    .whenComplete((result, ex) -> {
        if (ex == null) log.info("offset: {}", result.getRecordMetadata().offset());
        else log.error("send failed: {}", ex.getMessage());
    });
```

**Consumer side (Token Service):**
```java
// KafkaConsumerService.java
@KafkaListener(topics = TOKEN_VERIFICATION_TOPIC, groupId = "token-verification-group")
public void consumeTokenRequest(TokenRequest request) {
    tokenService.verifyAndTranslate(request);
}
```

The topic name `trust-broker.token.verification` is a constant in `KafkaTopicConfig` (in the common module), so both sides always agree on the topic without magic strings.

### Why Kafka (not REST)

The gateway returns an immediate `ACCEPTED` response to the caller — it does **not** wait for the token to be verified. This is a deliberate architectural decision:

- **Decoupling**: The gateway and token service scale independently
- **Back-pressure**: If the token service is slow, the Kafka consumer group naturally throttles — the gateway is unaffected
- **Audit trail**: Every message persisted in Kafka is an implicit audit log
- **Resilience**: If the token service is down, messages queue up and are processed when it recovers

The `KafkaProducerService` interface allows swapping to a different transport layer without changing `GatewayServiceImpl`.

### Infrastructure

The infrastructure (Zookeeper + Kafka + Redis) is defined in `docker/docker-compose.yml` using the Confluent Platform images. On a Mac with Apple Silicon, this runs inside **Colima** (a lightweight OCI container runtime) instead of Docker Desktop:

```bash
colima start    # start the VM
docker-compose -f docker/docker-compose.yml up
```

---

## 5. Phase 4 — Redis Caching & Real JWT Verification
**Commit:** `92dc28a` — *feat: implement Redis caching for JWKS and refactor token verification logic*

### What I built

This phase transforms the token service from a placeholder into a real cryptographic verifier.

**JwksService — the caching layer:**
```java
@Cacheable(value = "jwks", key = "'current_jwks'")
public String getJwksAsJson() {
    return restTemplate.getForObject(jwksUri, String.class);
}
```

Spring's `@Cacheable` with Redis as the backing store means:
- First call: fetches from the remote JWKS URI, stores in Redis
- Subsequent calls: served from Redis — **zero network latency**, **no dependency on the IdP being up**
- TTL is 24 hours (configured in `RedisCacheConfig`)

**TokenServiceImpl — real JWT decoding:**
```java
Jwt jwt = jwtDecoder.decode(request.getToken());
// Spring Security's JwtDecoder validates:
// - RSA signature against the JWKS
// - exp (expiry) claim
// - iat (issued at) claim
```

**RedisCacheConfig:**
```java
@Bean
public RedisCacheManager cacheManager(...) {
    return RedisCacheManager.builder(connectionFactory)
        .cacheDefaults(config.entryTtl(Duration.ofHours(24)))
        .withCacheConfiguration("jwks", config.entryTtl(Duration.ofHours(1)))
        .build();
}
```

### Why this matters for security

Fetching the JWKS on every token verification is:
1. **Slow**: Network RTT on every request
2. **Fragile**: If the IdP JWKS endpoint is down, verification fails
3. **A DDoS vector**: High token volume → high load on the IdP

Caching in Redis (with a reasonable TTL) solves all three. The trade-off is key rotation latency — if the IdP rotates keys, it takes up to 1 hour for the cache to pick up the new keys. This is standard practice.

---

## 6. Phase 5 — System Registry & Policy-Based Routing
**Commit:** `99d5c17` — *feat: integrate SystemRegistry and routing logic into GatewayServiceImpl*

### What I built

This is the **trust enforcement engine**. The `SystemRegistryServiceImpl` stores registered systems and their routing rules in Redis:

**Data model in Redis:**
```
system:{systemId}        → ExternalSystem object (JSON)
rule:{ruleId}            → RoutingRule object (JSON)
system_rules:{systemId}  → Set of ruleIds
```

**`GatewayServiceImpl` — the decision tree:**
```java
// 1. Is the system registered?
var systemOpt = systemRegistryService.getSystem(request.getSystemId());
if (systemOpt.isEmpty()) return buildRejectedResponse("System not registered");

// 2. Is the system active?
if (!system.isActive()) return buildRejectedResponse("System is inactive");

// 3. Does the system meet the minimum trust threshold?
if (system.getTrustLevel() == null || system.getTrustLevel() == TrustLevel.LOW)
    return buildRejectedResponse("Insufficient trust level");

// 4. Find routing rules, pick highest priority
var selectedRule = routingRules.stream()
    .sorted((r1, r2) -> Integer.compare(r2.getPriority(), r1.getPriority()))
    .findFirst().orElseThrow();

// 5. Route to the appropriate Kafka topic
kafkaProducerService.sendToTopic(topic, request);
```

**REST endpoints for registry management (on Gateway at 8081):**
- `POST /api/v1/registry/systems` — register a new external system
- `POST /api/v1/registry/rules` — add a routing rule
- `GET /api/v1/registry/systems` — list all systems

### Why Redis for the registry

I chose Redis over an RDBMS here because:
- **O(1) key-based lookup**: `SYSTEM_KEY_PREFIX + systemId` is a direct hash lookup
- **TTL support**: Systems can be auto-expired if needed
- **Already in the stack**: Redis was already required for JWKS caching — no new infra
- **Horizontal scalability**: Multiple gateway instances share one Redis — the registry is consistent across the cluster

---

## 7. Phase 6 — Token Signing with Normalized Claims
**Commit:** `e965009` — *feat: implement explicit token signing path with normalized identity claims and unit tests*

### What I built

After verifying the incoming JWT, the service **re-signs a brand new token** with enriched, UIDAI-specific claims:

```java
String normalizedName = originalName != null ? originalName.toUpperCase() : "UNKNOWN";

JwtClaimsSet claims = JwtClaimsSet.builder()
    .issuer("uidai-trust-broker")
    .issuedAt(now)
    .expiresAt(now.plus(Duration.ofMinutes(30)))
    .subject(jwt.getSubject())
    .claim("originSystem", request.getSystemId())
    .claim("trustLevel", "HIGH")
    .claim("tokenType", "SANDBOX_SESSION_TOKEN")
    .claim("normalizedName", normalizedName) // enriched claim
    .build();

String sessionToken = jwtEncoder.encode(JwtEncoderParameters.from(claims)).getTokenValue();
```

The result is a **Sandbox Session Token** — a new JWT signed by the Trust Broker's own private key, containing:
- The verified subject (`sub`)
- The originating system (`originSystem`)
- The trust level (`trustLevel`)
- A normalized name (`normalizedName` — uppercase, standardized)
- A 30-minute expiry

### The unit test — proving correctness via ArgumentCaptor

The key challenge was proving that the additional fields are embedded **in the signed token** (not just appended to the HTTP response). I used Mockito's `ArgumentCaptor` to capture what was actually passed to `jwtEncoder.encode()`:

```java
ArgumentCaptor<JwtEncoderParameters> captor = ArgumentCaptor.forClass(JwtEncoderParameters.class);
verify(jwtEncoder).encode(captor.capture());

JwtClaimsSet capturedClaims = captor.getValue().getClaims();

assertEquals("JANE DOE", capturedClaims.getClaim("normalizedName"));
assertEquals("SANDBOX_SESSION_TOKEN", capturedClaims.getClaim("tokenType"));
assertEquals("UID-789", capturedClaims.getSubject());
```

This test pattern — capturing and asserting on **what was passed to a dependency**, not just what was returned — is a more rigorous form of unit testing than just checking the response status.

A second test validates the **failure path**:
```java
when(jwtDecoder.decode(anyString())).thenThrow(new BadJwtException("Invalid token"));
TokenResponse response = tokenService.verifyAndTranslate(request);
assertEquals("FAILED", response.getStatus());
assertNull(response.getTranslatedToken());
```

---

## 8. Phase 7 — Security Hardening
**Commit:** `2da7a4b` — *fix: add gateway SecurityConfig and fix e2e_test.sh*

### What I built

Spring Security's auto-configuration generates a random password and blocks all endpoints by default. For a developer sandbox, this is counter-productive. I added explicit `SecurityConfig` classes to both services:

```java
// Gateway SecurityConfig
http
    .cors(cors -> cors.configurationSource(corsConfigurationSource()))
    .csrf(csrf -> csrf.disable())
    .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
```

CORS is configured to allow all origins in sandbox mode, which is appropriate for a local dev/integration environment. In production, this would be locked to specific allowed origins.

---

## 9. End-to-End Validation
**Script:** `e2e_test.sh`

### The full flow demonstrated live

```bash
sh e2e_test.sh
```

**Step 1 — Register an external system:**
```bash
POST /api/v1/registry/systems
{ "systemId": "UIDAI-SND-001", "trustLevel": "HIGH", "active": true }
# Stored in Redis as: system:UIDAI-SND-001
```

**Step 2 — Add a routing rule:**
```bash
POST /api/v1/registry/rules
{ "ruleId": "RULE-001", "systemId": "UIDAI-SND-001", "protocol": "KAFKA", "priority": 1 }
# Stored in Redis as: rule:RULE-001, and set: system_rules:UIDAI-SND-001
```

**Step 3 — Dispatch a token request:**
```bash
POST /api/v1/gateway/process
{ "systemId": "UIDAI-SND-001", "token": "eyJhbGci..." }
```

What happens internally:
1. Gateway looks up `UIDAI-SND-001` in Redis → found, active, trust=HIGH ✓
2. Fetches routing rules → RULE-001, protocol=KAFKA
3. Publishes `TokenRequest` to Kafka topic `trust-broker.token.verification`
4. Returns `{ "status": "ACCEPTED", "deliveryMode": "ASYNC_ROUTED" }` immediately

Meanwhile (asynchronously):
5. Token service's `KafkaConsumerService` picks up the message
6. Calls `tokenService.verifyAndTranslate(request)`
7. Decodes incoming JWT, normalizes name, re-signs new session token
8. Logs `"Issued new Sandbox Session Token for UID-789 with normalized name: JOHN DOE"`

**Actual output from the last run:**
```json
{
  "status": "ACCEPTED",
  "message": "Request validated and routed for processing.",
  "details": {
    "deliveryMode": "ASYNC_ROUTED",
    "trustLevel": "HIGH",
    "receivedAt": "2026-04-23T06:52:56.334301Z",
    "systemId": "UIDAI-SND-001",
    "gatewayId": "uidai-gateway-01"
  }
}
```

---

## 10. Architecture Summary

```
External System
      │
      ▼ POST /api/v1/gateway/process
┌─────────────────────────────────────┐
│  Interoperability Gateway (8081)    │
│  ┌─────────────────────────────┐    │
│  │  GatewayController          │    │
│  │  GatewayServiceImpl         │    │
│  │   ├─ SystemRegistryService  │◄───┼── Redis (system:*, rule:*)
│  │   └─ KafkaProducerService   │    │
│  └─────────────────────────────┘    │
└──────────────────┬──────────────────┘
                   │ Kafka: trust-broker.token.verification
                   ▼
┌─────────────────────────────────────┐
│  Token Verification Service (8082)  │
│  ┌─────────────────────────────┐    │
│  │  KafkaConsumerService       │    │
│  │  TokenServiceImpl           │    │
│  │   ├─ JwtDecoder             │◄───┼── Redis (jwks cache)
│  │   └─ JwtEncoder             │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

---

## 11. Key Design Decisions — Quick Reference

| Decision | Choice | Reason |
|---|---|---|
| Inter-service transport | Kafka (async) | Decoupling, back-pressure, audit log |
| System registry storage | Redis hash + set | O(1) lookup, shared across gateway instances |
| JWKS caching | Redis with @Cacheable | Avoid IdP dependency on every request |
| Multi-module structure | Maven parent POM | Single source of truth for versions, shared DTOs |
| Token format | RS256 JWT | Industry standard, verifiable without shared secret |
| Security in sandbox | Permit all (explicit) | Override Spring Boot's auto-locked default |
| Test isolation strategy | `@WebMvcTest` + `@MockBean` | Fast tests without Kafka/Redis context loading |
| Proof of field binding | `ArgumentCaptor` on JwtEncoder | Validates claims are *in the token*, not just the response |

---

## 12. What I Would Add Next

> *"If you had more time, what would you improve?"*

1. **Dead Letter Topic (DLT)**: The `KafkaConsumerService` currently logs errors and drops failed messages. In production, failed messages should go to a DLT for replay.
2. **Key rotation handling**: The JWKS cache needs a mechanism to invalidate on `kid` mismatch (when the token's key ID is not in the cached JWKS).
3. **Metrics**: Micrometer + Prometheus for per-system request rates, rejection rates, and Kafka consumer lag.
4. **Persistence**: Replace the Redis-only registry with a hybrid Redis + PostgreSQL setup — Redis for hot-path lookups, Postgres for audit history.
5. **Integration tests**: Use `@SpringBootTest` with embedded Kafka (via `spring-kafka-test`) and an embedded Redis to test the full async flow automatically.
