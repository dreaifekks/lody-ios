# Upstream Roost reader snapshot

Shared support files are from public Lody commit
[`5724451caeaca55035b6a44be065dbea407b8795`](https://github.com/LodyAI/Lody/commit/5724451caeaca55035b6a44be065dbea407b8795).
The owner transport cache remains at public Lody commit
[`878e55f8c62133482fc906049d1564d312243b0e`](https://github.com/LodyAI/Lody/commit/878e55f8c62133482fc906049d1564d312243b0e).
The session bridge, Streams replica, and shared cloud-history contract are copied
verbatim from public Lody source commit `51de5de4f4c1387eeba5b6e45ea04463ebaeeb08`.
`packages/acp-extension-dsh/src/capabilities.ts` is from its upstream submodule
commit `b1b0735fd8c38d191c87d6fbd14f7a27c0f0421e`, with its
[license](../../licenses/acp-extension-dsh-LICENSE.txt) in the runtime package.
The public `acp-extension-core` dependency is pinned to 0.3.0, whose source
matches the Lody submodule commit `ea90d0b23d4f850c66c0f542f53cbc596ef2c62f`.

To refresh, export each file's repository-relative path from its recorded public
source commit. Update the reader files together and record the pins in Android
provenance. Keep
the three browser export selectors (`entry.ts`, `shared-entry.ts`, `session-data.ts`)
local; they select public APIs without implementing Roost behavior.

The runtime bundle uses the published `@loro-dev/roost@0.3.2` SDK for framed
Streams reads. Run `node scripts/build-upstream-roost.mjs` to regenerate the runtime module.
The iOS asset build verifies the module. Android's runtime snapshot carries
the verified browser module and its license files.
