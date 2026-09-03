"""mojolint — pattern lints for the origin and thread-safety mistakes the
Mojo compiler accepts. Text-only by default; with `--lsp`, the rules ask
`mojo-lsp-server` for resolved types and name-resolved uses. A proof of
concept; see the README.
"""

from .facts import Facts, collect_facts
from .json import JsonDoc, json_quote, parse_json
from .lsp import LspBatch, LspReplies, Pos, hover_signature, hover_type
from .rules import Finding, Rule, lint_source, lint_with_facts, rules, run_rule
from .structure import Func, Module, Param, Struct, parse_module, parse_params
from .tokenize import Line, logical_lines, words_of
