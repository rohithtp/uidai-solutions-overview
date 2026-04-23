# Model Questions & Answers — UIDAI Technical Architect Assignment

> **Scope:** Covers Part 1 (System Design), Part 2 (Coding Challenge), and Part 3 (Scaling).
> Each answer is grounded in the actual implementation in this repository.

---

## Part 1 — Cross-Border Trust Broker (System Design)

---

### Q1. Walk me through the end-to-end flow when a foreign citizen authenticates through your gateway.

**A.**
The flow has four distinct phases:

1. **Foreign IdP → Gateway**: The foreign citizen authenticates with their national IdP (e.g., EU eIDAS node, Singapore Singpass). The IdP issues a signed JWT or a Verifiable Credential (VC). The downstream fintech app forwards this token to our Sandbox Interoperability Gateway at `POST /api/v1/gateway/process`.

2. **Trust check at the Gateway (8081)**: `GatewayServiceImpl` performs three checks in order:
   - Is the calling system registered? (`systemRegistryService.getSystem(systemId)`)
   - Is it active?
   - Does it meet the minimum trust level (not LOW)?
     If any check fails, the gateway immediately returns `REJECTED` with a reason.

3. **Async routing via Kafka**: On success, the gateway publishes the `TokenRequest` to the `trust-broker.token.verification` Kafka topic and returns `ACCEPTED` synchronously. The caller is not blocked waiting for cryptographic verification.

4. **Verification & translation (8082)**: `KafkaConsumerService` picks up the message. `TokenServiceImpl` decodes the JWT via the JWKS-backed `JwtDecoder`, normalizes the identity claims, and re-signs a new Sandbox Session Token using the Trust Broker's own private key. This token is then available for the downstream app.

---

### Q2. What identity protocols does your gateway bridge, and why did you choose them?

**A.**
The gateway is designed to bridge two primary standards:

- **OIDC (OpenID Connect)**: The most common protocol for modern IdPs. Foreign tokens arrive as OIDC JWTs. The `JwtDecoder` in Spring Security natively validates these against the IdP's JWKS endpoint.
- **W3C Verifiable Credentials (VC)**: For higher-assurance scenarios (e.g., EU eIDAS Level High), the gateway can accept a VC-JWT. The verification logic is the same — the credential is a signed JWT, just with a different claim structure.

I deliberately avoided SAML 2.0 as the primary path because it is XML-based, heavier to parse, and does not compose well with modern microservice architectures. SAML support could be added as a separate adapter module without changing the core gateway.

The **output** from our gateway is always a UIDAI Sandbox Session Token — a plain RS256 JWT signed by the Trust Broker. This normalizes the downstream experience: the fintech app only ever sees one token format regardless of which foreign IdP issued the original credential.

---

### Q3. How do you handle identity schema translation without hardcoding rules?

**A.**
The core insight is to treat schema translation as a **configuration problem, not a code problem**.

In my implementation, the first version normalizes the most universal fields (given name → full name uppercased) in code. But the production-grade approach uses a **Claim Mapping Registry** stored in Redis:

```
claim_map:{countryCode}:{foreignField} → localField
```

For example:

```
claim_map:EU:given_name    → givenName
claim_map:EU:family_name   → familyName
claim_map:SG:fullName      → givenName
claim_map:JP:namePart1     → givenName
```

The `TokenServiceImpl` reads the `iss` (issuer) claim to determine the origin country, then loads the country-specific mapping from Redis. No code change is needed to add a new country — an admin API call updates the mapping at runtime.

For LoA (Level of Assurance) translation, a second map converts foreign assurance levels to the UIDAI Sandbox's `LOW/MEDIUM/HIGH` enum:

```
loa_map:EU:substantial → MEDIUM
loa_map:EU:high        → HIGH
loa_map:SG:loa2        → MEDIUM
```

This pattern — data-driven transformation with a hot-reloadable registry — avoids the combinatorial explosion of hardcoded `if-else` chains.

---

### Q4. Why did you choose Kafka over synchronous REST calls between the gateway and the token service?

**A.**
Three production-grade reasons:

1. **Decoupling under load**: Kafka acts as a buffer. If the token service is slow (e.g., the JWKS fetch is taking 200ms), the gateway is unaffected — it always returns `ACCEPTED` in < 5ms. Without Kafka, a slow token service would cause the gateway's thread pool to exhaust, cascading into a gateway failure.

2. **Implicit audit log**: Every message published to `trust-broker.token.verification` is durably stored in Kafka. This is a free audit trail for compliance — who sent what token, when, from which system.

3. **Replay**: If the token service has a bug and is rolled back, messages queued in Kafka can be replayed against the fixed version. With synchronous REST, those requests are simply lost.

The trade-off is that the flow is now **eventually consistent** — the caller gets `ACCEPTED` immediately but the session token is issued asynchronously. For the fintech onboarding use case (where the user waits on a screen), this is fine. For a real-time POS payment scenario, I would use synchronous REST instead.

---

### Q5. Why did you use Redis for the System Registry instead of a relational database?

**A.**
Three reasons specific to this access pattern:

- **O(1) lookups by key**: `system:{systemId}` is a direct hash fetch. No SQL query planner, no table scan, no index warm-up. At 15,000 RPS, every microsecond matters.
- **Already in the stack**: Redis was already required for JWKS caching. Adding a PostgreSQL instance would be a new infrastructure dependency with its own failover requirements.
- **TTL support**: External system registrations can be set to auto-expire — useful for sandbox trial access with a fixed validity window.

The trade-off is durability. Redis persistence (AOF/RDB) is not as strong as PostgreSQL's WAL. My "what I'd add next" answer includes a hybrid: Redis for the hot path, PostgreSQL as the system of record for audit history.

---

### Q6. What does the `trust-broker-common` module contain, and why is it a separate module?

**A.**
`trust-broker-common` contains:

- **`TokenRequest` / `TokenResponse`** — the canonical DTOs shared across both services
- **`AuditEvent`** — structured event model for future audit trails
- **`KafkaTopicConfig`** — single constant for the topic name `trust-broker.token.verification`
- **`GlobalExceptionHandler`** — `@ControllerAdvice` for consistent error responses
- **`OpenApiConfig`** — Swagger/OpenAPI bean setup

It is a **separate Maven module** (not a library artifact, not a shared folder) because:

- Both services depend on it via `<dependency>` in their `pom.xml`, and Maven resolves it within the same reactor build
- A change to `TokenRequest` (e.g., adding a `correlationId` field) causes a compile error in both services simultaneously, making the contract unbreakable at build time
- Topic names as constants mean both the producer (`GatewayServiceImpl`) and consumer (`KafkaConsumerService`) can never disagree on the topic — typos are impossible

---

### Q7. How does your architecture handle the case where the foreign IdP's JWKS endpoint is temporarily down?

**A.**
This is handled by the Redis JWKS cache in `JwksService`:

```java
@Cacheable(value = "jwks", key = "'current_jwks'")
public String getJwksAsJson() {
    return restTemplate.getForObject(jwksUri, String.class);
}
```

With a 1-hour TTL configured in `RedisCacheConfig`, the JWKS is served from Redis even if the remote IdP is unreachable. The token service continues to verify tokens for up to 1 hour after the IdP goes dark.

For longer outages:

- The TTL is tunable per environment (1h for sandbox, configurable for production)
- On a cache miss (first request or after expiry), the service catches the `RestClientException` and returns a `FAILED` response with a clear error message rather than throwing an unhandled exception

What I would add: a **stale-while-revalidate** pattern — if the JWKS fetch fails on cache miss, serve the expired cached value for an additional grace period (e.g., 15 minutes) and trigger an async refresh.

---

### Q8. How would you handle JWKS key rotation?

**A.**
Key rotation is the most dangerous edge case in JWT verification. The scenario: the foreign IdP rotates its signing keypair, the new `kid` is not in our Redis cache, and tokens start failing verification.

My current implementation: the `JwtDecoder` from Spring Security resolves the key by `kid` from the JWKS. If the `kid` is not found, it throws `BadJwtException`. The `@Cacheable` TTL is 1 hour — after expiry, the next request fetches the new JWKS from the IdP.

**Production-grade enhancement**:
On `BadJwtException` with reason "unknown kid", the catch block should:

1. Evict the JWKS cache entry (`cacheManager.getCache("jwks").evict("current_jwks")`)
2. Force-fetch the JWKS from the IdP
3. Retry decoding once with the fresh JWKS

This is a **cache-aside with conditional invalidation** pattern — we only invalidate on a specific failure signal, not on a timer.

---

## Part 2 — Token Translation & Verification (Coding Challenge)

---

### Q9. Walk me through the token verification and translation flow in code.

**A.**
The full path through `TokenServiceImpl.verifyAndTranslate()`:

```java
// Step 1: Decode & verify the incoming JWT against the JWKS
Jwt jwt = jwtDecoder.decode(request.getToken());

// Step 2: Normalize the identity claims
String originalName = jwt.getClaimAsString("given_name");
String normalizedName = originalName != null ? originalName.toUpperCase() : "UNKNOWN";

// Step 3: Build a new claims set with UIDAI-specific fields
JwtClaimsSet claims = JwtClaimsSet.builder()
    .issuer("uidai-trust-broker")
    .issuedAt(now)
    .expiresAt(now.plus(Duration.ofMinutes(30)))
    .subject(jwt.getSubject())
    .claim("originSystem", request.getSystemId())
    .claim("trustLevel", "HIGH")
    .claim("tokenType", "SANDBOX_SESSION_TOKEN")
    .claim("normalizedName", normalizedName)
    .build();

// Step 4: Sign with the Trust Broker's own private key
String sessionToken = jwtEncoder.encode(JwtEncoderParameters.from(claims)).getTokenValue();
```

The key invariant: the **output token is signed by us** (the Trust Broker), not by the foreign IdP. Downstream apps only need to trust one issuer — `uidai-trust-broker`.

---

### Q10. Why do you use `jwtDecoder` and `jwtEncoder` as injected beans rather than instantiating them directly?

**A.**
Two reasons:

1. **Testability**: In `TokenServiceImplTest`, I mock both as `@MockBean`. The test never needs a real RSA keypair or a real JWKS endpoint. I can unit test the business logic (normalization, claim building) independently of cryptography.

2. **Configuration isolation**: The `JwtDecoder` is wired in `SecurityConfig` with the JWKS URI from `application.properties`. Changing the IdP URI requires only a config change, not a code change. The bean-wiring approach makes this a single-point-of-change.

---

### Q11. How do you prove in a unit test that custom claims are inside the signed token — not just appended to the HTTP response?

**A.**
Using Mockito's `ArgumentCaptor`:

```java
ArgumentCaptor<JwtEncoderParameters> captor =
    ArgumentCaptor.forClass(JwtEncoderParameters.class);
verify(jwtEncoder).encode(captor.capture());

JwtClaimsSet capturedClaims = captor.getValue().getClaims();

assertEquals("JANE DOE", capturedClaims.getClaim("normalizedName"));
assertEquals("SANDBOX_SESSION_TOKEN", capturedClaims.getClaim("tokenType"));
assertEquals("UID-789", capturedClaims.getSubject());
```

The captor intercepts what was actually passed to `jwtEncoder.encode()`. If the implementation only added `normalizedName` to the HTTP response DTO (not to the claims set), the assertion on `capturedClaims.getClaim("normalizedName")` would fail. This is a stricter correctness check than asserting on the HTTP response status alone.

---

### Q12. How do you handle the failure path — what happens if the incoming JWT is invalid?

**A.**
`JwtDecoder.decode()` throws `BadJwtException` for signature failures, expiry violations, or malformed tokens. The `try/catch` in `TokenServiceImpl` catches this:

```java
} catch (BadJwtException e) {
    log.warn("Token verification failed: {}", e.getMessage());
    return TokenResponse.builder()
        .status("FAILED")
        .message("Token verification failed: " + e.getMessage())
        .build();
}
```

The unit test explicitly validates this path:

```java
when(jwtDecoder.decode(anyString())).thenThrow(new BadJwtException("Invalid token"));
TokenResponse response = tokenService.verifyAndTranslate(request);
assertEquals("FAILED", response.getStatus());
assertNull(response.getTranslatedToken());
```

Key design choice: the `status` field is a string enum (`ACCEPTED`, `VERIFIED`, `FAILED`) rather than an HTTP status code. This decouples the domain result from the HTTP transport — the same DTO can be sent over Kafka or HTTP without changing its semantics.

---

### Q13. Why does `GatewayServiceImpl` return `ACCEPTED` immediately instead of waiting for the token to be verified?

**A.**
This is the **fire-and-forget routing pattern**. The gateway's contract with the caller is:

> "I have validated your identity as a registered system and accepted this request for processing. I cannot guarantee when it will be verified — that is an async concern."

This mirrors how real financial systems work (e.g., NEFT/RTGS batch processing). The benefits:

- **Gateway response time is O(1)**: Always < 10ms, regardless of JWKS fetch latency or token complexity
- **Horizontal scaling of verification is independent**: We can scale `token-verification-and-translation-service` pods without affecting gateway throughput
- **Backpressure is Kafka's job**: If the token service is overwhelmed, consumer lag increases — but the gateway never blocks

The caller must poll or receive a webhook callback to get the final `VERIFIED` status. This is by design.

---

### Q14. What does the `deliveryMode: ASYNC_ROUTED` field in the response mean?

**A.**
It signals to the caller the **routing mechanism** used for their request. The possible values are:

- `ASYNC_ROUTED` — request was published to a Kafka topic for async processing
- `SYNC_VERIFIED` — request was processed synchronously (future mode for direct REST routing)
- `REJECTED` — request was not routed (trust check failed)

The `deliveryMode` is part of the `details` map in `TokenResponse`. It allows the caller to decide their polling strategy — for `ASYNC_ROUTED`, they know to expect eventual delivery; for `SYNC_VERIFIED`, the result is in the response.

---

### Q15. How does the gateway pick which Kafka topic to route to?

**A.**
Via the routing rules stored in Redis. The flow in `GatewayServiceImpl`:

```java
List<RoutingRule> routingRules = systemRegistryService.getRulesForSystem(systemId);
RoutingRule selectedRule = routingRules.stream()
    .sorted((r1, r2) -> Integer.compare(r2.getPriority(), r1.getPriority()))
    .findFirst()
    .orElseThrow(() -> new RuntimeException("No routing rules found"));

String topic = selectedRule.getKafkaTopic(); // e.g., "trust-broker.token.verification"
kafkaProducerService.sendToTopic(topic, request);
```

Rules are sorted descending by `priority` — the highest-priority rule wins. This allows an admin to override routing for a specific system without changing code: add a new rule with `priority: 100` and it immediately takes precedence.

---

### Q16. How is the `SystemRegistry` data modeled in Redis?

**A.**
Three key patterns:

| Key Pattern               | Type          | Value                   |
| ------------------------- | ------------- | ----------------------- |
| `system:{systemId}`       | String (JSON) | `ExternalSystem` object |
| `rule:{ruleId}`           | String (JSON) | `RoutingRule` object    |
| `system_rules:{systemId}` | Set           | Set of `ruleId` strings |

To look up all rules for a system:

1. `SMEMBERS system_rules:{systemId}` → list of ruleIds
2. `GET rule:{ruleId}` for each → `RoutingRule` objects

This avoids a full table scan. The data model is optimized for the read path (system lookup + rule fetch), not the write path (registration is rare).

---

## Part 3 — The Scaling Crucible (Technical Judgment)

---

### Q17. At 15,000 RPS, what breaks first in your architecture?

**A.**
In order of failure likelihood:

1. **JWKS endpoint calls (most likely)**: If Redis is not pre-warmed and many concurrent requests miss the JWKS cache simultaneously (thundering herd on startup or after key rotation eviction), each triggers a synchronous HTTP call to the foreign IdP. At 15,000 RPS, this saturates the IdP within seconds.

2. **Kafka producer acknowledgment wait**: The `kafkaTemplate.send()` call is async but still blocks briefly waiting for broker acknowledgment (`acks=1` by default). Under extreme load, broker write latency spikes can cause producer backpressure.

3. **Redis connection pool exhaustion**: Both services share Redis for JWKS caching and the system registry. Under 15K RPS, connection pool saturation causes `RedisCommandTimeoutException` on registry lookups.

4. **Token signing CPU (least likely first-to-break)**: RSA-2048 signing is ~1ms on modern hardware. At 15K RPS this is 15 CPU-seconds/second — manageable with 4 pods but not infinite.

---

### Q18. How do you fix the JWKS thundering herd problem?

**A.**
Three complementary strategies:

**1. Singleton cache lock (immediate fix)**
Use Redis `SETNX` as a distributed lock around the JWKS fetch. Only one thread/pod fetches from the IdP; the rest wait for the lock to release and then read from Redis.

**2. Background refresh (preferred)**
Replace the on-demand `@Cacheable` pattern with a scheduled job that refreshes the JWKS every 45 minutes, regardless of request volume. The cache is always warm; requests never block on a JWKS fetch.

```java
@Scheduled(fixedDelay = 45 * 60 * 1000)
public void refreshJwks() {
    String jwks = restTemplate.getForObject(jwksUri, String.class);
    cache.put("current_jwks", jwks);
}
```

**3. Stale-while-revalidate**
On cache expiry, serve the stale value and trigger an async refresh. This eliminates cache miss latency entirely from the hot path.

---

### Q19. How would you use Kafka to decouple the cryptographic signing overhead?

**A.**
Currently, `TokenServiceImpl.verifyAndTranslate()` does both verification and signing synchronously in the Kafka listener thread. At high volume, this creates consumer lag.

Re-architecture:

```
Gateway → [verification-requests topic]
              ↓
        Verification workers (horizontally scaled)
              ↓ (on success)
        [signing-requests topic]
              ↓
        Signing workers (CPU-optimized pods)
              ↓
        [session-tokens topic]
              ↓
        Downstream app (or webhook callback)
```

Splitting into two topics allows:

- Verification pods to scale based on Kafka consumer lag
- Signing pods to be provisioned on CPU-optimized nodes (c-series on cloud)
- Independent failure isolation — a signing failure doesn't block pending verifications

---

### Q20. What Kubernetes autoscaling strategy would you apply?

**A.**
Two-tier autoscaling:

**HPA (Horizontal Pod Autoscaler) — for the token service:**
Scale based on **Kafka consumer lag** (via KEDA — Kubernetes Event-Driven Autoscaling), not CPU. CPU is a lagging indicator; consumer lag directly measures work backlog.

```yaml
# KEDA ScaledObject
triggers:
  - type: kafka
    metadata:
      topic: trust-broker.token.verification
      lagThreshold: "500" # scale up if lag > 500 messages
      bootstrapServers: kafka:9092
      consumerGroup: token-verification-group
```

**VPA (Vertical Pod Autoscaler) — for signing:**
RSA signing is single-threaded per request. Rather than scaling horizontally first, right-size the JVM heap and allocate 2 vCPUs per pod.

**Cluster Autoscaler:**
Pre-warm 3 standby nodes using **Kubernetes Cluster Autoscaler** with `--scale-down-delay-after-add=10m` to prevent aggressive scale-down during sustained load.

---

### Q21. How would you cache trust anchors (JWKS) securely at scale?

**A.**
Four properties of a secure trust anchor cache:

1. **Integrity**: The JWKS must be fetched over TLS. Pin the IdP's TLS certificate in the `RestTemplate` to prevent MITM substitution of the JWKS.

2. **Confidentiality**: Redis should run with `requirepass` and TLS (`redis-tls`) enabled. The JWKS contains public keys (not secret), but the cache store itself must not be writable by untrusted clients.

3. **Revocation awareness**: The cache should support per-`kid` entries, not just a monolithic JWKS blob. When a specific key is revoked, only that `kid` entry is evicted — not the entire JWKS.

4. **Warm-start**: On pod startup, pre-populate the JWKS cache before the pod accepts traffic (use a Kubernetes `initContainer` or startup probe that waits for the JWKS to be in Redis).

---

### Q22. How would you add observability to know when the system is degrading before it breaks?

**A.**
Three layers:

**Metrics (Micrometer + Prometheus):**

- `gateway.requests.total{systemId, status}` — rejection rate per system
- `token.verification.duration` — P50/P95/P99 of end-to-end verification time
- `kafka.consumer.lag{topic, group}` — leading indicator of processing backlog
- `jwks.cache.miss.total` — alert if > 0 during steady state (means cache is not working)

**Distributed Tracing (OpenTelemetry):**
Propagate a `correlationId` from the incoming request through Kafka headers to the token service. This allows a single trace to span both services asynchronously.

**Alerting thresholds:**

- `kafka.consumer.lag > 1000` for 2 minutes → PagerDuty P2
- `token.verification.duration.p99 > 2s` → PagerDuty P1
- `gateway.requests.total{status=REJECTED}` rate > 5% → Slack warning

---

### Q23. What would you put in a Dead Letter Topic (DLT), and how would you handle it?

**A.**
The DLT is for messages that fail processing after N retries. Currently, `KafkaConsumerService` logs and discards failed messages — a production gap.

**DLT design:**

- Topic: `trust-broker.token.verification.DLT`
- Message: original `TokenRequest` + `DltMetadata{reason, failedAt, retryCount, errorClass}`
- Consumer: A separate `DltConsumerService` that:
  1. Logs the failure to the audit database with `status=DEAD_LETTERED`
  2. Publishes a webhook callback to the originating system with `status=FAILED`
  3. Alerts on-call if `errorClass = SigningKeyNotFoundException` (key rotation issue)

**Retry strategy with Spring Kafka:**

```java
@Bean
public DefaultErrorHandler errorHandler(KafkaOperations<?, ?> template) {
    return new DefaultErrorHandler(
        new DeadLetterPublishingRecoverer(template),
        new FixedBackOff(1000L, 3) // 3 retries, 1s apart
    );
}
```

---

### Q24. How would you evolve the schema of `TokenRequest` without breaking existing consumers?

**A.**
Schema evolution in a Kafka-based system is a compatibility problem. My approach:

1. **Add fields as optional**: New fields added to `TokenRequest` must have defaults. Existing consumers that don't know about the new field simply ignore it (JSON deserialization with `FAIL_ON_UNKNOWN_PROPERTIES = false`).

2. **Use a Schema Registry** (e.g., Confluent Schema Registry with Avro or Protobuf): Producers register the schema; consumers validate against it. Forward and backward compatibility rules are enforced at produce time.

3. **Version the topic**: For breaking changes, introduce `trust-broker.token.verification.v2`. Run both topics in parallel during a migration window. Retire v1 after all consumers have migrated.

In the current implementation, Jackson is used for serialization with `@JsonIgnoreProperties(ignoreUnknown = true)` on the DTO — this gives us forward compatibility for free.

---

### Q25. How would you test the full async flow (Gateway → Kafka → Token Service) automatically?

**A.**
Using `@SpringBootTest` with embedded Kafka:

```java
@SpringBootTest
@EmbeddedKafka(
    partitions = 1,
    topics = {"trust-broker.token.verification"}
)
class E2EIntegrationTest {

    @Autowired GatewayController gatewayController;

    @Test
    void testFullFlow() throws Exception {
        // 1. Register system in Redis (via SystemRegistryService)
        // 2. POST to gateway
        // 3. Wait for Kafka consumer to process (CountDownLatch or Awaitility)
        // 4. Assert token service logged "Issued new Sandbox Session Token"
        Awaitility.await()
            .atMost(5, SECONDS)
            .until(() -> tokenServiceLog.contains("Issued new Sandbox Session Token"));
    }
}
```

Spring Boot's `@EmbeddedKafka` spins up an in-process Kafka broker — no Docker needed. `Awaitility` handles the async assertion without `Thread.sleep()`. This test validates the complete async pipeline in CI/CD.

---

### Q26. If you had to add SAML 2.0 support alongside OIDC, how would you do it without changing the core gateway?

**A.**
Using the **Adapter Pattern** at the gateway entry point.

I would introduce a `ForeignTokenAdapter` interface:

```java
public interface ForeignTokenAdapter {
    boolean supports(String contentType, String protocolHint);
    TokenRequest adapt(HttpServletRequest raw) throws AdaptationException;
}
```

Two implementations:

- `OidcJwtAdapter` — parses Bearer tokens, extracts JWT
- `SamlAssertionAdapter` — parses SAML XML, extracts the identity assertion, converts to `TokenRequest`

`GatewayController` selects the adapter based on request headers (e.g., `Content-Type: application/samlassertion+xml`). Once adapted to `TokenRequest`, the rest of the flow (trust check → Kafka → token service) is identical for both protocols.

This is open/closed: the gateway is open for extension (new adapters) but closed for modification (no `if protocol == SAML` in the core flow).

---

### Q27. How does your implementation address the OWASP Top 10 risks relevant to an identity gateway?

**A.**

| Risk                           | Mitigation in this project                                                                                           |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| **A01 Broken Access Control**  | `GatewayServiceImpl` rejects unregistered systems and systems below trust threshold before processing any token      |
| **A02 Cryptographic Failures** | RS256 JWT validation via JWKS (asymmetric); no shared secrets; TLS on all external calls                             |
| **A03 Injection**              | Jackson deserialization with schema validation; `systemId` is looked up by exact key — no SQL or shell interpolation |
| **A07 Auth Failures**          | Spring Security `SecurityConfig` explicitly permits only defined paths; no default password exposure                 |
| **A09 Logging Failures**       | `@Slf4j` on all service layers; `AuditEvent` DTO for structured event logging to Kafka                               |

The most important one for an identity gateway is A02. The decision to use asymmetric RS256 (JWKS) rather than symmetric HS256 (shared secret) means the Trust Broker never has to handle or rotate a shared secret. The foreign IdP's public key is fetched dynamically — the gateway has zero shared-secret surface area.

---

### Q28. What is the `GlobalExceptionHandler` in `trust-broker-common`, and why is it there?

**A.**
`GlobalExceptionHandler` is a `@ControllerAdvice` class that intercepts unhandled exceptions from any controller in both services:

```java
@ExceptionHandler(Exception.class)
public ResponseEntity<TokenResponse> handleAll(Exception ex) {
    return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
        .body(TokenResponse.builder()
            .status("ERROR")
            .message("Internal error: " + ex.getMessage())
            .build());
}
```

It lives in `trust-broker-common` so that both services share the same error response format. Without this, Spring Boot would return its default `application/json` error body (with `timestamp`, `path`, `error`) — a different schema from `TokenResponse`. Consumers would have to handle two different error shapes.

By centralizing it in the common module, the error contract is as strong as the success contract — one DTO for all responses.

---

_Document last updated: 2026-04-23_
