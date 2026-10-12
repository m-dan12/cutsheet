from shot_type.classify import (FEET, HIPS, KNEES, SHOULDERS, Box, FrameObservation, Landmark, Pose, Texture,
                                Verdict, aggregate, classify_frame)

PERSON = Box(0.3, 0.1, 0.7, 1.0)


def pose(*visible_groups: tuple[int, ...]) -> Pose:
    """Поза, у которой в кадре только точки из перечисленных групп (и нос)."""
    shown = {0, *(i for g in visible_groups for i in g)}
    return Pose(tuple(Landmark(0.5, 0.1 + 0.025 * i, 0.9) if i in shown else Landmark(0.5, 1.3, 0.1)
                      for i in range(33)))


def test_pose_rules():
    def shot(*groups, faces=()):
        return classify_frame(FrameObservation(poses=[pose(*groups)], persons=[PERSON], faces=list(faces))).shot_type

    assert shot(SHOULDERS, HIPS, KNEES, FEET) == "wide"
    assert shot(SHOULDERS, HIPS, KNEES) == "medium"
    assert shot(SHOULDERS, HIPS) == "medium"
    assert shot(SHOULDERS) == "close"
    assert shot() == "close"  # видно только лицо
    assert shot(faces=[Box(0.1, 0.0, 0.9, 0.9)]) == "detail"


def test_pose_without_person_or_face_is_ignored():
    # Модель позы находит «позы» у животных; без человека в кадре решают предметы.
    obs = FrameObservation(poses=[pose(SHOULDERS, HIPS)], objects=[Box(0.1, 0.1, 0.4, 0.4)])
    assert classify_frame(obs) == Verdict("wide", 0.35, "object")


def test_face_and_person_fallbacks():
    assert classify_frame(FrameObservation(faces=[Box(0.4, 0.2, 0.6, 0.5)])).shot_type == "close"
    assert classify_frame(FrameObservation(faces=[Box(0.4, 0.2, 0.5, 0.32)])).shot_type == "medium"
    assert classify_frame(FrameObservation(faces=[Box(0.4, 0.2, 0.42, 0.23)])).shot_type == "wide"
    assert classify_frame(FrameObservation(persons=[Box(0.4, 0.5, 0.5, 0.8)])).shot_type == "wide"
    assert classify_frame(FrameObservation(persons=[Box(0.2, 0.2, 0.8, 1.0)])).shot_type == "medium"


def test_no_people():
    assert classify_frame(FrameObservation(objects=[Box(0.1, 0.1, 0.9, 0.8)])).shot_type == "detail"
    assert classify_frame(FrameObservation(texture=Texture(20.0, 4.0))).shot_type == "detail"
    assert classify_frame(FrameObservation(texture=Texture(10.0, 9.0))).shot_type == "wide"
    flat = classify_frame(FrameObservation(texture=Texture(0.2, 0.1)))
    assert flat == Verdict("unknown", 0.0, "none")


def test_aggregate_weighted_majority():
    v = aggregate([Verdict("medium", 0.8, "pose"), Verdict("close", 0.6, "face"), Verdict("medium", 0.5, "face")])
    assert v.shot_type == "medium" and v.confidence == round(1.3 / 3, 3)
    assert aggregate([Verdict("unknown", 0.0, "none")] * 2).shot_type == "unknown"
    assert aggregate([]).shot_type == "unknown"
    # Ничья — в пользу более общего плана.
    assert aggregate([Verdict("close", 0.5, "face"), Verdict("wide", 0.5, "face")]).shot_type == "wide"
