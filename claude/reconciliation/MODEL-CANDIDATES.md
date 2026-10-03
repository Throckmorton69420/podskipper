# Requested model identities and research provenance

This appendix preserves candidate intent under M14. Names are copied from user evidence or current source, not a claim about current vendor availability, hardware compatibility, superiority, footprint or licensing. The documentation audit did not re-benchmark or re-download these models. Source summaries containing “tested 30 Sep” remain old diagnostic claims and do not close Build 301 acceptance.

## Explicit candidate requests

H118 asks to download/test models from the quoted shortlist and share diagnostics; it does not adopt its ranking, estimated phone feasibility, runtime support claims or advice to drop Bonsai. H119 gives an explicit additional list; H120–H122 report missing choices/errors and object to conflated identities/up-front refusal.

| Requested identity | Origin | Audited repository representation / remaining distinction |
|---|---|---|
| Ternary Bonsai8B; Bonsai8B1-bit; Bonsai27B | H102–H107; H121–H122 | All three retained as experimental download candidates; embedded27B superseded by in-app download. LocallyAI anecdote is not PodSkipper quality. |
| Qwen3.5 4B | H118 | MLX catalogue entry exists; C012/F301 unfinished Basic tests remain open. |
| Qwen3.5 4B Instruct | H119–H120 | Separate ALTICDEV Q6 entry exists; do not call ordinary Qwen3.5 4B the requested Instruct variant. |
| Qwen3 4B through Core AI | C012/F301 selected model example | Distinct from Qwen3.5 and MLX; unfinished Basic test requires actual runtime/device evidence. |
| MiniCPM5 2B / 1B | H118/H119 | Both source entries exist; specific OptiQ/format request from quoted recommendation needs identity verification, not assumed matching. |
| LFM2.5 2.6B / 350M | H118/H119 | Both source entries exist; thinking/completion/quality claims remain evidence-gated. |
| Gemma4 Mobile E2B / E4B (user spells EB4) | H118/H119 | Both E2B/E4B entries exist; verify intended variant, runtime and measured cost. |
| Ministral3 3B Reasoning | H118 adopted candidate list | Source has Ministral3 3B **Instruct2512**, which does not establish the requested Reasoning variant. Keep mismatch open. |
| Nemotron3 Nano4B | H118; H121–H122; C012 | MLX entry has a config patch; Core AI startup/phone outcome still fails. Config comment “so it loads” is not current verification. |
| SmolLM3 3B | H118 | Source entry exists; prior unsafe whole-sample cut claim is diagnostic history, not a default candidate win. |
| Phi4 mini3.8B / Phi3 Mini3.8B | H119 | Both source entries exist; correct format/runtime/quality still to verify. |
| Gemma3 4B Instruct | H119 | Gemma3 4B `it-qat-4bit` source entry; validate intended conversion and runtime. |
| Llama3.2 3B Instruct / Dolphin Llama3.2 3B | H119 | Both source entries exist; distinguish base/fine-tuned identities. |
| Granite4.0 H Micro / H1B | H118/H119 | Both source entries exist. |
| Granite3.1 2B | H119 | **Missing source catalogue entry** at ad592214. Research actual compatible downloadable artifact and preserve honest unsupported reason if unavailable. |
| Ternary Bonsai4B /1.7B | H119 | Both source entries exist; no silent omission based only on model-size estimates. |

## Advisory research that is not a current implementation mandate

H100 provider research includes Gemini/Mistral/Cloudflare/gpt-oss/free-credit comparisons; the user was open to investigation. It does not approve arbitrary cloud transmission, a current provider default, credentials in the repo or copied pricing claims as fact. Q006/Q007 are dated answers; C005 controls current local default and evidence-gated model strategy. Prior retries followed by a notification offering Reader are retained in M17.

H103/H118 also quote proposals for larger Qwen3.5 9B/Qwen3 8B, LFM8B, Ministral8B, Gemma4 E4B and tiny specialized DistilBERT/ModernBERT/MiniLM/ad-classifier pipelines, datasets and multi-stage alternatives. Preserve as research suggestions; verify actual artifacts/APIs/data quality before promoting any to a requirement. Reader training is deferred D07. The public-dataset/SponsorBlock suggestion is restricted by W05. No third-party general benchmark proves ad-boundary quality, and no assistant claim proves MLX hardware placement or Core AI adapter availability.

## Exact source catalogue at audited head

The following 24 entries are source definitions, **not 24 compatible phone-verified models**. Repository identifier and pinned revision must be part of any download/result identity. Dynamic Core AI catalogue availability is runtime-dependent and is not inferred from this MLX list.

| Source name | Repository identifier | Pinned revision |
|---|---|---|
| Ternary Bonsai 8B | `prism-ml/Ternary-Bonsai-8B-mlx-2bit` | `9260b24298e4211e804663e9f519962cf59f34be` |
| Bonsai 8B 1-bit | `prism-ml/Bonsai-8B-mlx-1bit` | `019934f87a61a654e3960ea22f53688e0d2c49ba` |
| Bonsai 27B 1-bit | `prism-ml/Bonsai-27B-mlx-1bit` | `ef22f239c670078e1507f9769bcaa66657332b96` |
| Qwen3.5 4B | `mlx-community/Qwen3.5-4B-MLX-4bit` | `32f3e8ecf65426fc3306969496342d504bfa13f3` |
| MiniCPM5 2B | `openbmb/MiniCPM5-2B-MLX` | `8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3` |
| LFM2.5 2.6B | `LiquidAI/LFM2.5-2.6B-MLX-4bit` | `04efa23776ce61ec34ec95ec34c859854c89542b` |
| Gemma 4 E2B | `mlx-community/gemma-4-e2b-it-4bit` | `238767527555cb75a05732a84dff5d6ba0dd6809` |
| Ministral 3 3B | `mlx-community/Ministral-3-3B-Instruct-2512-4bit` | `a962dcb09eee4169c890e544c9eb938f1113fdee` |
| Nemotron 3 Nano 4B | `mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit` | `c4d79ba1901d99806ef757642a552acebb851a35` |
| SmolLM3 3B | `mlx-community/SmolLM3-3B-4bit` | `d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce` |
| Qwen3.5 2B | `mlx-community/Qwen3.5-2B-MLX-4bit` | `93760be4f1f69842a46bc13dbdc0f19e291392a3` |
| MiniCPM5 1B | `openbmb/MiniCPM5-1B-MLX` | `9879b18bf2928355fcdf4287635388a3665a40cb` |
| Phi-4 mini 3.8B | `mlx-community/Phi-4-mini-instruct-4bit` | `ac1c269cb4222a4e136a3d09edad301056c1f36a` |
| Llama 3.2 3B | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` |
| Gemma 3 4B | `mlx-community/gemma-3-4b-it-qat-4bit` | `3d9ef289111449933c22761961f16a5df237ce2a` |
| Granite 4.0 H Micro | `mlx-community/granite-4.0-h-micro-4bit` | `0a29e17503da7de371af61a0a532853810637627` |
| Granite 4.0 H 1B | `mlx-community/granite-4.0-h-1b-4bit` | `a5a21e23f01a461f501dcd2b7a34c9efc6fba6a6` |
| LFM2.5 350M | `LiquidAI/LFM2.5-350M-MLX-4bit` | `f6cb4e006bb7a2d8a6afa14ec0a53e0586f65a5b` |
| Ternary Bonsai 4B | `prism-ml/Ternary-Bonsai-4B-mlx-2bit` | `e1374ad6bf9b1b56afd743936b8faa33c409a75f` |
| Ternary Bonsai 1.7B | `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit` | `5f3e306330f636cfc6c6241b4850fae6711c5985` |
| Qwen3.5 4B Instruct (6-bit) | `ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6` | `00a036421c2f892d998408e53a38cbb332d56d7a` |
| Gemma 4 E4B | `mlx-community/gemma-4-e4b-it-4bit` | `475b9088d29754a3379866cf5aeb6b41acd313c2` |
| Phi-3 mini 3.8B | `mlx-community/Phi-3-mini-4k-instruct-4bit` | `5b3819ed6317784fb20eddeae9bed984f778d0d0` |
| Dolphin 3.0 Llama 3.2 3B | `mlx-community/dolphin3.0-llama3.2-3B-4Bit` | `cdc777b578ff86a69f1b05c9bc00df0cdc2f52d1` |
