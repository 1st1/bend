# AI for Swift

AI for Swift implements the non-durable core of ai-python: model streaming, local tool execution, and nested agents. This graph describes the implemented contracts and the tests that protect them.

- [[sdk-architecture]] — package boundaries, composition, and serializable data.
- [[sdk-streaming]] — single-turn requests, event delivery, results, and cancellation.
- [[sdk-agents]] — the agent loop, execution limits, tool errors, and subagents.
- [[sdk-provider]] — request translation, SSE framing, completion rules, and HTTP transport.
- [[sdk-tests]] — existing test coverage, linked back from test code.
- [[sdk-development]] — build commands, fixture infrastructure, and the runnable example.

For API usage examples and installation instructions, see [[docs/ai-sdk.md]]. These documents describe current behavior rather than a roadmap or complete Python API parity.
