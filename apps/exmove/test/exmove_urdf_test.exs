defmodule ExMove.URDFTest do
  use ExUnit.Case, async: true

  alias ExMove.{FK, Frame, JointState, URDF}

  @moduledoc """
  Reading a mechanism out of a document.

  The test this file exists for is the first one: a URDF whose joints are
  emitted in a scrambled order has to produce the same arm as one where they
  are not. The loader this replaced took chain order from document order, which
  URDF does not guarantee, and it passed every test written against the file it
  was developed on — so the fixture is scrambled on purpose and the assertion
  compares against the tidy version rather than against a hand-typed answer.

  The rest are refusals, and they assert the *message*. A URDF this build
  cannot honour has to fail as a sentence somebody can act on: "link `torso`
  has 2 joints hanging off it" is a bug report, "invalid URDF" is a support
  call.
  """

  defp fixture(name), do: Path.join(__DIR__, "fixtures/#{name}.urdf")

  describe "the tree, not the document order" do
    test "a scrambled file produces the same chain as a tidy one" do
      {:ok, tidy} = URDF.parse_file(fixture("ordered"))
      {:ok, scrambled} = URDF.parse_file(fixture("shuffled"))

      assert Enum.map(tidy.joints, & &1.name) == ~w(shoulder elbow wrist_1)
      assert Enum.map(scrambled.joints, & &1.name) == ~w(shoulder elbow wrist_1)

      for {a, b} <- Enum.zip(tidy.joints, scrambled.joints) do
        assert a.origin == b.origin
        assert a.axis == b.axis
        assert a.limit == b.limit
      end
    end

    test "and the fixture really is adversarial" do
      # Guards the test above from passing for nothing. If somebody tidied the
      # fixture, the scrambled case would agree with the tidy one by accident
      # and the assertion would stop testing the walk at all — which is the
      # same shape of quiet failure as the bug it was written for.
      document_order =
        fixture("shuffled")
        |> File.read!()
        |> then(&Regex.scan(~r/<joint\s+name="([^"]+)"/, &1))
        |> Enum.map(fn [_full, name] -> name end)

      {:ok, chain} = URDF.parse_file(fixture("shuffled"))

      assert document_order != Enum.map(chain.joints, & &1.name),
             "the shuffled fixture is in tree order, so it proves nothing"
    end

    test "and therefore the same tool centre point" do
      {:ok, tidy} = URDF.parse_file(fixture("ordered"))
      {:ok, scrambled} = URDF.parse_file(fixture("shuffled"))
      pose = %JointState{positions: [0.3, -0.4, 0.9]}

      assert FK.solve(tidy, pose) == FK.solve(scrambled, pose)
    end
  end

  describe "what it reads" do
    test "origins, axes and travel come off the document" do
      {:ok, chain} = URDF.parse_file(fixture("ordered"))
      [shoulder, elbow, wrist] = chain.joints

      assert shoulder.origin == {0.0, 0.0, 0.2}
      assert shoulder.axis == {0.0, 0.0, 1.0}
      assert shoulder.limit == {-3.0, 3.0}
      assert shoulder.max_vel == 1.0

      assert elbow.axis == {1.0, 0.0, 0.0}

      # `continuous` is revolute with nowhere to stop, and nil is how the rest
      # of this suite says "no software limit".
      assert wrist.type == :revolute
      assert wrist.limit == nil
    end

    test "the chain is named after the robot unless told otherwise" do
      assert {:ok, %{name: :ordered}} = URDF.parse_file(fixture("ordered"))
      assert {:ok, %{name: :arm_a}} = URDF.parse_file(fixture("ordered"), name: :arm_a)
    end

    test "no axis ids are invented" do
      # Which drive turns joint 3 is a fact about an installation, and a
      # document exported from CAD has never seen the installation.
      assert {:ok, %{axis_ids: []}} = URDF.parse_file(fixture("ordered"))
    end

    test "forward kinematics at zero is the sum of the link lengths" do
      {:ok, chain} = URDF.parse_file(fixture("ordered"))

      assert %Frame{x: x, y: y, z: z} = FK.solve(chain, %JointState{positions: [0.0, 0.0, 0.0]})
      assert_in_delta x, 0.0, 1.0e-12
      assert_in_delta y, 0.0, 1.0e-12
      assert_in_delta z, 0.9, 1.0e-12
    end
  end

  describe "fixed joints" do
    test "one in the middle folds into the joint after it" do
      {:ok, chain} = URDF.parse_file(fixture("flanged"))

      assert [shoulder] = chain.joints
      # 0.1 of pedestal plus 0.2 of its own origin. The arm has one axis and it
      # is 300mm up, which is a fact the document only states in two pieces.
      assert {_x, _y, z} = shoulder.origin
      assert_in_delta z, 0.3, 1.0e-12
    end

    test "a trailing one is the flange, not a joint and not a tool" do
      {:ok, chain} = URDF.parse_file(fixture("flanged"))

      assert %Frame{z: 0.05} = chain.flange
      # And it is not the tool: nothing has been fitted to this arm.
      assert chain.tool == %Frame{}
    end

    test "a chain of nothing but fixed joints is refused" do
      urdf = """
      <robot name="statue">
        <link name="base_link"/><link name="top"/>
        <joint name="weld" type="fixed">
          <origin xyz="0 0 1"/><parent link="base_link"/><child link="top"/>
        </joint>
      </robot>
      """

      assert {:error, {:no_actuated_joints, message}} = URDF.parse_string(urdf)
      assert message =~ "nothing to move"
    end
  end

  describe "refusals name the thing" do
    test "a branch names the link it forks at" do
      assert {:error, {:branch, message}} = URDF.parse_file(fixture("branched"))
      assert message =~ "torso"
      assert message =~ "left_shoulder"
      assert message =~ "right_shoulder"
    end

    test "xacro is refused with the command that fixes it" do
      urdf = ~s(<robot name="a" xmlns:xacro="http://ros.org/wiki/xacro"><xacro:property name="w" value="1"/></robot>)

      assert {:error, {:xacro, message}} = URDF.parse_string(urdf)
      assert message =~ "xacro robot.xacro"
    end

    test "a prismatic joint is refused rather than silently rotated" do
      # The failure this prevents is the quiet one: forward kinematics here and
      # in the NIF applies a rotation to every joint without consulting its
      # type, so a prismatic axis would turn instead of extend and the pose
      # would look entirely plausible.
      urdf = """
      <robot name="gantry">
        <link name="base_link"/><link name="carriage"/>
        <joint name="rail" type="prismatic">
          <origin xyz="0 0 0"/><parent link="base_link"/><child link="carriage"/>
          <axis xyz="1 0 0"/><limit lower="0" upper="1.5"/>
        </joint>
      </robot>
      """

      assert {:error, {:prismatic, message}} = URDF.parse_string(urdf)
      assert message =~ "rail"
    end

    test "a mimic joint is refused, because a coupled axis is not an independent one" do
      urdf = """
      <robot name="gripper">
        <link name="base_link"/><link name="finger_a"/><link name="finger_b"/>
        <joint name="left_finger" type="revolute">
          <origin xyz="0 0 0"/><parent link="base_link"/><child link="finger_a"/>
          <axis xyz="0 0 1"/><limit lower="0" upper="1"/>
        </joint>
        <joint name="right_finger" type="revolute">
          <origin xyz="0 0 0"/><parent link="finger_a"/><child link="finger_b"/>
          <axis xyz="0 0 1"/><limit lower="0" upper="1"/>
          <mimic joint="left_finger" multiplier="-1"/>
        </joint>
      </robot>
      """

      assert {:error, {:mimic, message}} = URDF.parse_string(urdf)
      assert message =~ "right_finger"
    end

    test "two disconnected mechanisms are refused, and counted" do
      urdf = """
      <robot name="two_arms">
        <link name="a0"/><link name="a1"/><link name="b0"/><link name="b1"/>
        <joint name="a" type="revolute">
          <origin xyz="0 0 1"/><parent link="a0"/><child link="a1"/>
          <axis xyz="0 0 1"/><limit lower="-1" upper="1"/>
        </joint>
        <joint name="b" type="revolute">
          <origin xyz="0 0 1"/><parent link="b0"/><child link="b1"/>
          <axis xyz="0 0 1"/><limit lower="-1" upper="1"/>
        </joint>
      </robot>
      """

      assert {:error, {:disconnected, message}} = URDF.parse_string(urdf)
      assert message =~ "2 separate mechanisms"
    end

    test "an unknown joint type is refused rather than treated as fixed" do
      urdf = """
      <robot name="odd">
        <link name="base_link"/><link name="top"/>
        <joint name="floaty" type="floating">
          <origin xyz="0 0 1"/><parent link="base_link"/><child link="top"/>
        </joint>
      </robot>
      """

      assert {:error, {:unknown_joint_type, message}} = URDF.parse_string(urdf)
      assert message =~ "floaty"
      assert message =~ "floating"
    end

    test "a joint with no parent or child is refused" do
      urdf = """
      <robot name="loose">
        <link name="base_link"/>
        <joint name="orphan" type="revolute">
          <origin xyz="0 0 1"/><axis xyz="0 0 1"/><limit lower="-1" upper="1"/>
        </joint>
      </robot>
      """

      assert {:error, {:unlinked_joint, message}} = URDF.parse_string(urdf)
      assert message =~ "orphan"
    end

    test "something that is not a robot at all is refused by its root element" do
      assert {:error, {:not_urdf, message}} = URDF.parse_string(~s(<launch><node/></launch>))
      assert message =~ "<launch>"
    end

    test "malformed XML is refused as malformed" do
      assert {:error, {:malformed, _message}} = URDF.parse_string("<robot name=")
    end

    test "a missing file says which file" do
      assert {:error, {:unreadable, message}} = URDF.parse_file("/nope/missing.urdf")
      assert message =~ "missing.urdf"
    end
  end

  describe "the real arm" do
    test "the Arctos export loads, and it is the one in priv" do
      assert {:ok, chain} = URDF.load(:arctos)

      assert length(chain.joints) == 6
      assert Enum.map(chain.joints, & &1.name) == ~w(joint1 joint2 joint3 joint4 joint5 joint6)
      assert chain.flange == %Frame{}
    end

    test "its reach is the sum of what the document says, near enough" do
      {:ok, chain} = URDF.load(:arctos)
      here = %JointState{positions: List.duplicate(0.0, 6)}

      assert %Frame{} = pose = FK.solve(chain, here)

      # Straight up at zero, and every joint origin has a positive Z, so the
      # tool centre point is above the base by more than the tallest link and
      # less than the sum of every offset's magnitude.
      assert pose.z > 0.4
      assert pose.z < 1.0
    end
  end
end
