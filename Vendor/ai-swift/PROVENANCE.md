# AI for Swift source

Based on `/Users/yury/dev/vercel/ai-swift` at commit `aec8fc853cc8cc65708ef760f5bce3a7d30e367b`, with native Gateway adapters, search events, reasoning summaries and their tests synchronized through SDK commit `2ad6366`. This local Swift package keeps Bend builds reproducible. LICENSE and NOTICE apply.

Upstream Lat comments were removed because their section identifiers belong to the upstream knowledge graph. The agent normalizes empty arguments for explicitly parameterless tools to `{}` after a complete model response, including retained history. Regression tests cover the Gateway SSE-to-tool path and preserve rejection of malformed or required arguments. Run `swift test --package-path Vendor/ai-swift` for the upstream offline suite.

Gateway-hosted web search options and server-tool usage events are synchronized with the local ai-swift source checkout. Search request and metadata regression coverage is included in the vendored provider tests.

Native Anthropic Messages and OpenAI Responses adapters, native history fields and search events are synchronized with the local SDK. The agent handles paused server turns while retaining Bend’s parameterless-tool normalization.
