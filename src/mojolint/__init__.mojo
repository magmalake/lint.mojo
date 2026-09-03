"""mojolint — source-level pattern lints for the origin and thread-safety
mistakes the Mojo compiler accepts. A proof of concept; see the README.
"""

from .rules import Finding, Rule, lint_source, rules, run_rule
from .structure import Func, Module, Param, Struct, parse_module, parse_params
from .tokenize import Line, logical_lines, words_of
