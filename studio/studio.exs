# Launch E-Motion Studio.
#
#     mix run studio.exs
#
# The application's supervision tree is already up by the time this runs — Job,
# the cell, and Boot — so all this does is start the scene and stay alive.

Logger.configure(level: :info)

Cedar.start_scene(EMotion.Shell)

unless IEx.started?() do
  Process.sleep(:infinity)
end
