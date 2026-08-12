# E-Motion Studio

A desktop environment for programming and simulating multi-arm robot cells.

## Why it is not an umbrella app

The umbrella under `apps/` is the *runtime*: drives, kinematics, fieldbus,
G-code — things that run on a controller, headless, beside hardware. The studio
is a tool that talks to those. Making it an umbrella member would put wxWidgets
and OpenGL in the dependency graph of everything that ships to a machine with
no display.

So it sits alongside the umbrella and reaches into it by path. The arrow points
from the tool at the runtime and never back: `ExMove` does not know the studio
exists, and nothing in `apps/` may ever depend on it.

```
exmo/
  apps/          runtime — ships to controllers
  studio/        this — ships to engineers
```

## Running it

```sh
cd studio
mix deps.get
mix test
```

Requires an Erlang built with wxWidgets and an OpenGL 4.1 driver — see
`wx_mvu`'s README, which this depends on for rendering.

## Units

Everything inside the studio is in **canonical SI**: metres, radians, seconds,
newtons, newton-metres. There are no millimetres in the model and no degrees,
ever. Display units exist at exactly two edges — parsing what an operator typed
and formatting what they read — and `EMotion.Units` owns both.

This is the first module because mixing units is the most expensive routine bug
in motion software, and it is expensive precisely because it does not fail. A
joint commanded to 90 when it wanted 1.5708 does not crash; it drives the arm
into a fixture. A tool offset entered in millimetres and stored as metres
produces parts wrong by a factor of a thousand, days later, in a batch nobody
re-measured.

The canonical set is chosen to match what `ExMove` already documents, so
crossing that boundary is never a conversion.

## Where this is going

Roughly in order, and none of it is built yet:

1. **Transform hierarchy** — a kinematic tree the renderer walks, so setting
   joint three moves everything downstream of it. `wx_mvu`'s `:layers` is
   deliberately not a scene graph; this needs one.
2. **Model loading** — binary STL first, since that is what most robot
   description packages ship, baked to a compressed term the way `wx_mvu` bakes
   its font, so opening a cell does not mean parsing meshes.
3. **Picking** — unproject a screen ray, intersect it with link bounds, so an
   operator can click a joint. Needs a 4x4 inverse, which the math layer does
   not have yet.
4. **Camera** — orbit, pan, dolly, and the standard iso/top/front views. Pure
   model state driven by the mouse events `wx_mvu` already delivers.
5. **Frames** — named coordinate frames and the transforms between them. A
   number can be in metres and still be measured from the wrong origin, which
   is the other half of the problem `EMotion.Units` solves half of.

Kinematics itself is not on that list: `ExMove` has forward kinematics, inverse
kinematics and URDF loading already. The studio is a view onto it.
