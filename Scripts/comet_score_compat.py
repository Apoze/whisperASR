#!/usr/bin/env python3
"""Run COMET 2.2.7 with Homebrew Python's extended argparse signature."""

import argparse
import inspect


parse_known_args = argparse.ArgumentParser._parse_known_args
if "intermixed" in inspect.signature(parse_known_args).parameters:
    argparse.ArgumentParser._parse_known_args = lambda self, args, namespace: (
        parse_known_args(self, args, namespace, False)
    )

from comet.cli.score import score_command


score_command()
