# Hardware-in-the-loop tests are tagged :hardware and excluded by default —
# they require the Stage 1 board plugged in and enumerated. Run them with:
#   mix test --include hardware
ExUnit.start(exclude: [:hardware])
