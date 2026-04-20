
**Candidate:** Rohith Pavithran
**Role:** Technical Architect

---

## 1) Problem Framing

The core problem is fairly straightforward on the surface:

> How do we let a foreign citizen authenticate using their home identity system and still interact securely with applications inside the UIDAI Sandbox?

But in practice, this is less about authentication and more about **trust translation**.

We’re taking identities issued by external systems (which we don’t control), verifying them, reshaping them, and then issuing something our ecosystem can trust. That boundary — where external trust becomes internal trust — is where most complexity sits.

---

## 2) Design Approach (High-Level)

The system follows a **trust-broker pattern** with a clear separation of responsibilities.

At a high level, the flow looks like this:

A user authenticates with a foreign Identity Provider (OIDC, OAuth2, or sometimes a Verifiable Credential flow). That token is sent to the **Interoperability Gateway**, which acts as a thin entry layer — it validates the request shape, applies rate limits, and routes it forward.

The actual trust decision is made by a downstream **Token Verification & Translation Service**. This service:

* verifies the token signature using keys resolved dynamically (JWKS)
* validates claims like issuer, audience, and expiry
* translates the identity into a canonical sandbox format
* issues a new Sandbox Session Token

Kafka and Redis support the system in the background — Kafka for audit and async processing, Redis for caching trust-related data.

👉 One important design choice here is keeping the gateway intentionally thin. In similar systems, once business logic creeps into the gateway, it quickly becomes a bottleneck.

---

## 3) Handling Multiple Identity Standards

In reality, different countries and partners will use different identity protocols. Trying to standardize them upfront rarely works.

So instead, the gateway acts as an abstraction layer and supports:

* OIDC / OAuth2 (most common)
* JWT-based federation
* Verifiable Credentials / DID (emerging)
* SAML for legacy integrations

The goal is not to unify protocols, but to **contain that variability at the edges** so the rest of the system stays stable.

---

## 4) Identity Normalization (Where It Gets Tricky)

Normalization is where things usually get complicated.

Identity data varies a lot — name formats, address structures, even basic fields like date of birth can differ across countries. Hardcoding mappings quickly becomes unmanageable.

So the system uses a **config-driven normalization approach**:

* a canonical identity schema inside the sandbox
* country/provider-specific adapters defined via configuration
* mapping rules expressed declaratively (JSON/YAML)

This keeps onboarding new partners relatively simple.

That said, in practice, normalization is rarely perfect. Some fields are missing, some are ambiguous, and some don’t map cleanly.

👉 In real-world systems, this is where subtle bugs creep in. If you don’t track normalization failures explicitly, they tend to go unnoticed until they cause downstream issues.

---

## 5) Trust & Security Considerations

This system sits on a critical boundary, so the design leans heavily toward being defensive.

A few principles guide it:

* Always verify signatures before trusting any data
* Resolve keys dynamically using `kid` (JWKS)
* Validate issuer, audience, and expiry strictly
* Fail closed when trust cannot be established

One thing to note: key rotation and JWKS instability are not edge cases — they happen regularly.

👉 Many production issues in systems like this don’t come from bad code, but from **external dependencies behaving unpredictably**.

So caching (with safe refresh strategies) and fallback handling become just as important as the core verification logic.

---

## 6) Scaling Considerations

At moderate scale, this system works comfortably. But as we move toward something like 15,000 RPS, a few pressure points show up quickly:

* repeated JWKS lookups
* cryptographic verification overhead
* CPU cost of normalization

If not handled well, these start compounding.

The approach to scaling is fairly pragmatic:

* Cache trust anchors aggressively (with expiry and refresh)
* Keep the request path minimal (verification + token issuance only)
* Push audit and non-critical work to Kafka
* Scale gateway and verification services independently

👉 A useful rule of thumb: systems like this usually don’t fail all at once — they degrade slowly due to latency from external calls and CPU-heavy operations.

---

## 7) Why This Design Works

This design is intentionally not overcomplicated.

It keeps concerns separated, avoids hardcoding identity logic, and builds around the reality that external trust systems are inconsistent and sometimes unreliable.

Kafka, Redis, and Kubernetes provide the infrastructure for scale, but the real strength lies in how the system handles uncertainty — whether that’s changing schemas, rotating keys, or unstable upstream providers.

If there’s one principle driving the design, it’s this:

> **Trust should always be explicit — never assumed.**

---

## Repository

[https://github.com/rohithtp/uidai-sandbox-trust-broker](https://github.com/rohithtp/uidai-sandbox-trust-broker)
