# Design decisions

Each decision is taken one at a time, and recorded with the options rejected and why.

| ADR | Decision |
|---|---|
| [0001](0001-query-ir.md) | Structured query format |
| [0002](0002-ui-delivery.md) | UI delivery: a command palette as a web component |
| [0003](0003-positioning-and-security-order.md) | Positioning, security additions and development order |
| [0004](0004-declaration-dsl.md) | Declaration DSL |
| [0005](0005-compiler.md) | Compiler: from a validated query to ActiveRecord |
| [0006](0006-evaluation-dataset.md) | Evaluation dataset: domain, languages, authorship |
| [0007](0007-catalog-narrowing.md) | Narrowing the catalog before the query |
| [0008](0008-llm-adapter.md) | The LLM adapter |
| [0009](0009-baseline.md) | The naive baseline: model and prompt |
| [0010](0010-ways-in.md) | The ways in: `DataTeller.ask`, the endpoint, the helper, and who is asking |
| [0011](0011-isolation-kit.md) | The isolation kit: proving tenant isolation on the integrator's own tables |
| [0012](0012-aggregate-disclosure.md) | Aggregate disclosure: a minimum group size per dataset |
| [0013](0013-query-budget.md) | The query budget: a time per question, and an optional cost estimate |
| [0014](0014-always-conditions.md) | Conditions always applied: `always` on a dataset |
| [0015](0015-eval-executor-without-user.md) | The eval runs a query from a role and a tenant, not a user |
| [0016](0016-lists.md) | Lists: an answer that shows rows |
