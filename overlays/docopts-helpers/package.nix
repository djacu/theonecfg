{ writeShellScript, docopts }:
writeShellScript "docopts-helpers" (builtins.readFile "${docopts.src}/docopts.sh")
