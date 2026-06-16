// SPDX-License-Identifier: GPL-3.0-or-later
import WhisperKit

// Echo defines its own `TranscriptionSegment`, and `WhisperKit.…` qualification
// resolves into the WhisperKit *class* rather than the module. This file
// imports only WhisperKit, so the bare name is unambiguous here and tests can
// use the alias.
typealias WKTranscriptionSegment = TranscriptionSegment
