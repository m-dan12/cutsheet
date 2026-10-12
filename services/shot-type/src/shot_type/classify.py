"""Крупность плана по наблюдениям детекторов (FR-ST1–ST3). Чистая логика, без моделей.

Главный признак — какие части тела главного персонажа видны в кадре (поза MediaPipe):
видны стопы → общий план, колени или бёдра → средний, только плечи и голова → крупный,
лицо занимает почти весь кадр → деталь. Если поза не найдена, крупность оценивается
по высоте лица, затем по рамке человека. Поза без человека и лица в кадре не учитывается
(модель позы находит «позы» и у животных).

Без людей (FR-ST3): крупный предмет в кадре — деталь; мелкие предметы — общий план. Если
предметов не найдено — эвристика резкости: резкий центр при размытых краях (малая глубина
резкости) — деталь, равномерно резкий кадр — общий (пейзаж, интерьер); однотонный — unknown.

Итог сцены — взвешенное по уверенности большинство кадров (FR-ST2).
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field

ALGORITHM_VERSION = "shot-rules-v1"
SHOT_TYPES = ("wide", "medium", "close", "detail", "unknown")

# Индексы точек позы BlazePose (33 точки).
NOSE, L_SHOULDER, R_SHOULDER = 0, 11, 12
L_HIP, R_HIP, L_KNEE, R_KNEE, L_ANKLE, R_ANKLE = 23, 24, 25, 26, 27, 28
FEET = (L_ANKLE, R_ANKLE, 29, 30, 31, 32)
KNEES = (L_KNEE, R_KNEE)
HIPS = (L_HIP, R_HIP)
SHOULDERS = (L_SHOULDER, R_SHOULDER)

MIN_VISIBILITY = 0.5
EDGE_MARGIN = 0.02        # точка у самой границы кадра считается обрезанной


@dataclass(frozen=True)
class Box:
    """Нормированная рамка: доли ширины и высоты кадра."""
    x0: float
    y0: float
    x1: float
    y1: float
    score: float = 1.0

    @property
    def height(self) -> float:
        return max(0.0, self.y1 - self.y0)

    @property
    def area(self) -> float:
        return max(0.0, self.x1 - self.x0) * self.height


@dataclass(frozen=True)
class Landmark:
    x: float
    y: float
    visibility: float = 1.0

    def in_frame(self) -> bool:
        return (self.visibility >= MIN_VISIBILITY
                and EDGE_MARGIN <= self.x <= 1 - EDGE_MARGIN and EDGE_MARGIN <= self.y <= 1 - EDGE_MARGIN)


@dataclass(frozen=True)
class Pose:
    landmarks: tuple[Landmark, ...]   # 33 точки BlazePose

    def visible(self, ids: tuple[int, ...]) -> bool:
        return any(self.landmarks[i].in_frame() for i in ids if i < len(self.landmarks))

    def box(self) -> Box:
        pts = [p for p in self.landmarks if p.visibility >= MIN_VISIBILITY] or list(self.landmarks)
        return Box(min(p.x for p in pts), min(p.y for p in pts), max(p.x for p in pts), max(p.y for p in pts))


@dataclass(frozen=True)
class Texture:
    """Резкость кадра (средний модуль лапласиана): в центральной области и по краям."""
    center: float
    border: float


@dataclass
class FrameObservation:
    poses: list[Pose] = field(default_factory=list)
    faces: list[Box] = field(default_factory=list)
    persons: list[Box] = field(default_factory=list)
    objects: list[Box] = field(default_factory=list)    # всё, кроме людей
    texture: Texture | None = None


@dataclass(frozen=True)
class Verdict:
    shot_type: str
    confidence: float
    basis: str            # pose | face | person | object | texture | none


# Пороги по высоте лица (доля высоты кадра) и по резкости. Подбираются на реальных фильмах (этап 6).
FACE_DETAIL = 0.75
FACE_CLOSE = 0.22
FACE_MEDIUM = 0.08
PERSON_SMALL = 0.45       # человек ниже этой доли кадра — общий план
OBJECT_DETAIL = 0.3       # предмет занимает такую долю площади кадра — деталь
FLAT_TEXTURE = 1.5        # кадр почти однотонный
SHALLOW_DOF = 2.5         # центр во столько раз резче краёв — малая глубина резкости


def classify_frame(obs: FrameObservation) -> Verdict:
    if obs.poses and (obs.persons or obs.faces):
        return _by_pose(max(obs.poses, key=lambda p: p.box().area), obs.faces)
    if obs.faces:
        return _by_face(max(f.height for f in obs.faces))
    if obs.persons:
        return _by_person(max(obs.persons, key=lambda b: b.area))
    if obs.objects:
        return _by_objects(max(b.area for b in obs.objects))
    return _by_texture(obs.texture)


def _by_pose(pose: Pose, faces: list[Box]) -> Verdict:
    face = max((f.height for f in faces), default=0.0)
    if face >= FACE_DETAIL:
        return Verdict("detail", 0.7, "pose")
    if pose.visible(FEET):
        # Маленькая фигура в кадре — тем более общий план.
        return Verdict("wide", 0.85 if pose.box().height < 0.9 else 0.75, "pose")
    if pose.visible(KNEES) or pose.visible(HIPS):
        return Verdict("medium", 0.8, "pose")
    if pose.visible(SHOULDERS) or pose.visible((NOSE,)):
        return Verdict("close", 0.75, "pose")
    return Verdict("unknown", 0.0, "pose")


def _by_face(height: float) -> Verdict:
    if height >= FACE_DETAIL:
        return Verdict("detail", 0.65, "face")
    if height >= FACE_CLOSE:
        return Verdict("close", 0.6, "face")
    if height >= FACE_MEDIUM:
        return Verdict("medium", 0.5, "face")
    return Verdict("wide", 0.5, "face")


def _by_person(box: Box) -> Verdict:
    if box.height < PERSON_SMALL:
        return Verdict("wide", 0.55, "person")
    # Рамка упирается в нижний край — фигура обрезана: средний план или ближе.
    if box.y1 >= 0.97:
        return Verdict("medium", 0.45, "person")
    return Verdict("wide", 0.5, "person")


def _by_objects(area: float) -> Verdict:
    if area >= OBJECT_DETAIL:
        return Verdict("detail", 0.45, "object")
    return Verdict("wide", 0.35, "object")


def _by_texture(t: Texture | None) -> Verdict:
    if t is None or max(t.center, t.border) < FLAT_TEXTURE:
        return Verdict("unknown", 0.0, "none")
    if t.center >= SHALLOW_DOF * max(t.border, 1e-6):
        return Verdict("detail", 0.35, "texture")
    return Verdict("wide", 0.3, "texture")


def aggregate(verdicts: list[Verdict]) -> Verdict:
    """Взвешенное большинство по кадрам сцены. Уверенность — доля веса победителя от числа кадров."""
    weights: dict[str, float] = defaultdict(float)
    for v in verdicts:
        if v.shot_type != "unknown":
            weights[v.shot_type] += v.confidence
    if not weights:
        return Verdict("unknown", 0.0, "none")
    # При равенстве весов побеждает более общий план (порядок SHOT_TYPES).
    best = max(weights, key=lambda s: (weights[s], -SHOT_TYPES.index(s)))
    basis = next(v.basis for v in verdicts if v.shot_type == best)
    return Verdict(best, round(min(1.0, weights[best] / len(verdicts)), 3), basis)
