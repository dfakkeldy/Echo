# mini-bart-g2p Provenance and Bundling Review

- Review date: 2026-08-04
- Reviewer: OpenAI Codex (engineering provenance review)
- Verdict: `COMPATIBLE_FOR_BUNDLING`
- Scope: the six files pinned by `Tools/Pronunciation/mini_bart_g2p.lock.json`

This is an engineering compatibility review, not legal advice. The verdict means
the authoritative upstream records identify licenses that permit redistribution
when their attribution and notice conditions are followed. The six locked files
are now committed under
`EchoCore/Services/Narration/NeuralG2PResources/` and copied into the iOS,
macOS, and `echo-cli` resource bundles. This review does not replace a
release-specific legal review.

## Model identity and license

- Artifact repository: [jonschneider/mini-bart-g2p](https://huggingface.co/jonschneider/mini-bart-g2p)
- Immutable revision: [`f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06`](https://huggingface.co/jonschneider/mini-bart-g2p/tree/f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06)
- Pinned model card: [README.md](https://huggingface.co/jonschneider/mini-bart-g2p/blob/f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06/README.md)
- Pinned license: [Apache License 2.0](https://huggingface.co/jonschneider/mini-bart-g2p/blob/f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06/LICENSE)
- Canonical license terms: [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)

The pinned model card labels the model `apache-2.0`, states that the model is
licensed under Apache 2.0, and identifies LibriSpeech Alignments and CMUdict as
its training sources. The pinned `LICENSE` is the standard Apache License 2.0
text. Apache 2.0 permits reproduction and distribution in source or object form,
subject to its conditions, including providing a copy of the license and
retaining applicable attribution notices.

Inference, clearly labeled: the pinned repository file listing contains no
`NOTICE` file, so there is no separate upstream `NOTICE` content to reproduce for
this revision. A distribution that bundles these model artifacts must still ship
the exact locked `LICENSE` and the applicable attributions below.

## Training-data provenance

### LibriSpeech Alignments

- Record: [Loren Lugosch, “LibriSpeech Alignments,” version 1.0](https://zenodo.org/records/2619474)
- DOI: [10.5281/zenodo.2619474](https://doi.org/10.5281/zenodo.2619474)
- License recorded by Zenodo: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/legalcode)
- Underlying corpus: [OpenSLR SLR12, LibriSpeech ASR corpus](https://www.openslr.org/12/), also identified there as CC BY 4.0

The exact Zenodo record named by the model card says the alignment archive covers
980 hours of LibriSpeech and records license identifier `cc-by-4.0`. CC BY 4.0
allows sharing and adaptation, including commercially, provided attribution and
the other license conditions are met. Attribution for the alignments is retained
here by creator, title, version, DOI, and license link.

### CMUdict

- Upstream: [cmusphinx/cmudict](https://github.com/cmusphinx/cmudict)
- Echo's independently pinned source revision: [`74790861f652b15e4ac49015a90074ad62a27690`](https://github.com/cmusphinx/cmudict/tree/74790861f652b15e4ac49015a90074ad62a27690)
- License: [pinned CMUdict license](https://github.com/cmusphinx/cmudict/blob/74790861f652b15e4ac49015a90074ad62a27690/LICENSE)

CMUdict permits redistribution and use in source and binary forms, with or
without modification, provided its notice and disclaimer conditions are met.
Echo already preserves the complete pinned notice in `THIRD_PARTY_NOTICES.md`
and `ThirdParty/CMUdict/LICENSE`.

## Locked artifacts

All URLs in the lock use HTTPS and contain the immutable revision. The fetcher
streams each download, validates exact size and SHA-256 before atomic rename,
and requires the license file as part of the same locked artifact set.

| Path | Bytes | SHA-256 |
| --- | ---: | --- |
| `onnx/encoder_model.onnx` | 6,634,844 | `5df81746fe1872b63aa120205ce267ed44163b7894a54e931a1d4b4b09568faa` |
| `onnx/decoder_model.onnx` | 9,999,491 | `2c199ceaa241186259167a8e79c5ff3498609ee8fc01c28c8a3d76a351d33c3d` |
| `tokenizer.json` | 3,212 | `40193885f8093d3bf59dfc199db502cfa8618b24bfcb2d08aa5f8d538bc34495` |
| `config.json` | 1,066 | `d647577ad51cacdab20f82c479ab8fd75ae569edba480475ca6c732881256415` |
| `generation_config.json` | 182 | `f36f1cb8f814ff32f744ced2e00610ce37de166d5a21bd92050972e220fa0449` |
| `LICENSE` | 11,356 | `43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1` |

Total locked size: 16,650,151 bytes.

## Tokenizer contract

The [pinned tokenizer](https://huggingface.co/jonschneider/mini-bart-g2p/blob/f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06/tokenizer.json)
is a version 1.0 `WordLevel` tokenizer with a 103-token shared vocabulary. It:

- lowercases input;
- splits a single input word into characters;
- recognizes lowercase Latin letters plus apostrophe, hyphen, and period as
  input punctuation tokens;
- wraps the sequence with `<s>` (ID 0) and `</s>` (ID 2), uses `<pad>` (ID 1),
  `<unk>` (ID 3), and `<mask>` (ID 4), and truncates on the right at 128 tokens;
- represents output as uppercase ARPAbet-style phoneme tokens, including vowel
  stress digits 0, 1, and 2.

The model card further limits the behavioral contract to one English word per
input and warns that non-apostrophe punctuation can produce inconsistent output.
Later runtime work must preserve this exact tokenizer/model pairing rather than
substituting a moving or independently generated tokenizer.

## Attribution and distribution conditions

A bundle containing these model files must:

1. include the exact locked Apache 2.0 `LICENSE` file;
2. retain applicable model-origin and training-source attributions from this
   report and `THIRD_PARTY_NOTICES.md`;
3. retain the complete CMUdict notice and disclaimer already present in Echo;
4. attribute the LibriSpeech Alignments record to Loren Lugosch with its title,
   version, DOI, and CC BY 4.0 license link; and
5. distribute only files that pass the immutable lock's size and SHA-256 checks.

The original verified fetch used only a caller-supplied external temporary
directory. The resulting six byte-for-byte locked artifacts are now committed
under `EchoCore/Services/Narration/NeuralG2PResources/` and explicitly copied by
all three product resource phases: iOS, macOS, and `echo-cli`. Runtime model
downloads are neither required nor permitted by this Stage 3 integration; every
bundled artifact must continue to match the sizes and SHA-256 values above.
