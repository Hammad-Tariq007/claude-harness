# Claude harness shell aliases.
# Install once per machine:
#   echo "source ~/claude-harness/aliases.sh" >> ~/.bashrc && source ~/.bashrc

alias ticket='./scripts/run-ticket.sh'      # ticket 42
alias tonight='./scripts/run-night.sh'      # tonight 2 5
alias tickets='gh issue list --label agent-ready'
alias parked='ls .agent-logs/*/PARKED 2>/dev/null | sed "s|.agent-logs/||;s|/PARKED||" || echo "none parked"'
alias agentlog='tail -f .agent-logs/$(ls -t .agent-logs | head -1)/run.log'
