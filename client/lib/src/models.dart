class Project {
  Project({
    required this.id,
    required this.name,
    required this.stage,
    required this.status,
    this.error,
    this.videoUri,
    this.fps,
    this.durationMs,
    required this.createdAt,
    this.reviewRequired = true,
  });

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: j['name'] as String,
        stage: j['stage'] as String,
        status: j['status'] as String,
        error: j['error'] as String?,
        videoUri: j['video_uri'] as String?,
        fps: (j['fps'] as num?)?.toDouble(),
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
        reviewRequired: j['review_required'] as bool? ?? true,
      );

  final String id;
  final String name;
  final String stage;
  final String status;
  final String? error;
  final String? videoUri;
  final double? fps;
  final int? durationMs;
  final DateTime createdAt;

  /// false — режим «без правок» (FR-C12): ревью необязательно, лист только для просмотра.
  final bool reviewRequired;

  Project withStatus(StatusUpdate s) => Project(
        id: id,
        name: name,
        stage: s.stage,
        status: s.status,
        error: s.error,
        videoUri: videoUri,
        fps: fps,
        durationMs: durationMs,
        createdAt: createdAt,
        reviewRequired: reviewRequired,
      );
}

/// Сообщение хаба "status" (payload события project.status-changed).
class StatusUpdate {
  StatusUpdate({required this.projectId, required this.stage, required this.status, this.progress, this.error});

  factory StatusUpdate.fromJson(Map<String, dynamic> j) => StatusUpdate(
        projectId: j['project_id'] as String,
        stage: j['stage'] as String,
        status: j['status'] as String,
        progress: (j['progress'] as num?)?.toDouble(),
        error: j['error'] as String?,
      );

  final String projectId;
  final String stage;
  final String status;
  final double? progress;
  final String? error;
}

/// Авто-значение поля сцены (scene_auto_values): что предложила автоматика и с какой уверенностью.
class AutoValue {
  AutoValue({this.value, this.confidence, required this.source});

  factory AutoValue.fromJson(Map<String, dynamic> j) => AutoValue(
        value: j['value'],
        confidence: (j['confidence'] as num?)?.toDouble(),
        source: j['source'] as String,
      );

  final Object? value;
  final double? confidence;
  final String source;
}

/// Реплика в строке листа. [matched] = false — речь не найдена в сценарии (FR-C8).
class Replica {
  Replica({
    this.id,
    this.startMs,
    this.endMs,
    this.role,
    required this.text,
    this.spokenText,
    this.confidence,
    this.matched = false,
    this.origin = 'user',
    this.edited = const [],
  });

  factory Replica.fromJson(Map<String, dynamic> j) => Replica(
        id: j['id'] as String,
        startMs: (j['start_ms'] as num).toInt(),
        endMs: (j['end_ms'] as num).toInt(),
        role: j['role'] as String?,
        text: j['text'] as String,
        spokenText: j['spoken_text'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble(),
        matched: j['matched'] as bool? ?? false,
        origin: j['origin'] as String? ?? 'auto',
        edited: (j['edited'] as List? ?? const []).cast<String>(),
      );

  /// null — новая реплика, ещё не сохранённая.
  final String? id;
  final int? startMs;
  final int? endMs;
  final String? role;
  final String text;
  final String? spokenText;
  final double? confidence;
  final bool matched;
  final String origin;
  final List<String> edited;

  /// Элемент тела PUT /scenes/{id}/replicas.
  Map<String, Object?> toJson() => {
        if (id != null) 'id': id,
        'role': role,
        'text': text,
        if (id == null && startMs != null) 'start_ms': startMs,
        if (id == null && endMs != null) 'end_ms': endMs,
      };

  /// «РОЛЬ: текст», как в экспорте (FR-E2).
  String get line => role == null ? text : '$role: $text';
}

/// Строка монтажного листа (FR-C4).
class Scene {
  Scene({
    required this.id,
    required this.index,
    required this.startMs,
    required this.endMs,
    this.shotType,
    this.description,
    required this.status,
    this.rowVersion = 1,
    this.origin = 'auto',
    this.needsEnrichment = false,
    required this.keyframeUrls,
    this.edited = const [],
    this.auto = const {},
    this.replicas = const [],
  });

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'] as String,
        index: (j['index'] as num).toInt(),
        startMs: (j['start_ms'] as num).toInt(),
        endMs: (j['end_ms'] as num).toInt(),
        shotType: j['shot_type'] as String?,
        description: j['description'] as String?,
        status: j['status'] as String,
        rowVersion: (j['row_version'] as num?)?.toInt() ?? 1,
        origin: j['origin'] as String? ?? 'auto',
        needsEnrichment: j['needs_enrichment'] as bool? ?? false,
        keyframeUrls: (j['keyframe_urls'] as List).cast<String>(),
        edited: (j['edited'] as List? ?? const []).cast<String>(),
        auto: (j['auto'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, AutoValue.fromJson(v as Map<String, dynamic>))),
        replicas: (j['replicas'] as List? ?? const [])
            .map((r) => Replica.fromJson(r as Map<String, dynamic>))
            .toList(),
      );

  final String id;
  final int index;
  final int startMs;
  final int endMs;
  final String? shotType;
  final String? description;
  final String status;
  final int rowVersion;

  /// user — строка создана человеком (split, добавление).
  final String origin;

  /// Границы менял человек: план и описание относятся к старым границам (ТЗ 6.2).
  final bool needsEnrichment;
  final List<String> keyframeUrls;

  /// Поля, изменённые пользователем (FR-C9).
  final List<String> edited;
  final Map<String, AutoValue> auto;
  final List<Replica> replicas;

  bool isEdited(String field) => edited.contains(field);

  /// Авто-значение отличается от того, что в строке: автоматика предлагает другое (ТЗ 6.2).
  bool autoDiffers(String field) {
    final a = auto[field];
    if (a == null || !isEdited(field)) return false;
    return a.value != (field == 'shot_type' ? shotType : description);
  }

  /// Низкая уверенность автоматики (FR-C8): поле не правили, а уверенность ниже порога.
  bool lowConfidence(String field, {double threshold = 0.5}) {
    final c = auto[field]?.confidence;
    return !isEdited(field) && c != null && c < threshold;
  }
}

/// Справочник планов (FR-ST1): код из контракта → подпись.
const shotTypeLabels = {
  'wide': 'Общий',
  'medium': 'Средний',
  'close': 'Крупный',
  'detail': 'Деталь',
  'unknown': 'Не определён',
};

class SceneSheet {
  SceneSheet({
    this.fps,
    this.durationMs,
    this.videoUrl,
    this.reviewRequired = true,
    this.structureEdited = false,
    this.shotTypes = const ['wide', 'medium', 'close', 'detail', 'unknown'],
    this.roles = const [],
    required this.scenes,
  });

  factory SceneSheet.fromJson(Map<String, dynamic> j) => SceneSheet(
        fps: (j['fps'] as num?)?.toDouble(),
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        videoUrl: j['video_url'] as String?,
        reviewRequired: j['review_required'] as bool? ?? true,
        structureEdited: j['structure_edited'] as bool? ?? false,
        shotTypes: (j['shot_types'] as List? ?? const ['wide', 'medium', 'close', 'detail', 'unknown']).cast<String>(),
        roles: (j['roles'] as List? ?? const []).cast<String>(),
        scenes: (j['scenes'] as List).map((s) => Scene.fromJson(s as Map<String, dynamic>)).toList(),
      );

  final double? fps;
  final int? durationMs;

  /// Presigned URL видео для встроенного плеера (FR-C7).
  final String? videoUrl;
  final bool reviewRequired;
  final bool structureEdited;
  final List<String> shotTypes;
  final List<String> roles;
  final List<Scene> scenes;

  /// Тот же лист с заменёнными строками (ответ на правку одной строки).
  SceneSheet withScenes(List<Scene> changed) {
    final byId = {for (final s in changed) s.id: s};
    final roles = {...this.roles, ...changed.expand((s) => s.replicas).map((r) => r.role).nonNulls}.toList()..sort();
    return SceneSheet(
      fps: fps,
      durationMs: durationMs,
      videoUrl: videoUrl,
      reviewRequired: reviewRequired,
      structureEdited: structureEdited,
      shotTypes: shotTypes,
      roles: roles,
      scenes: [for (final s in scenes) byId[s.id] ?? s],
    );
  }
}

class PartUrl {
  PartUrl(this.partNumber, this.url);
  final int partNumber;
  final String url;
}

/// Ответ POST/GET /projects/{id}/uploads: части, которые ещё нужно загрузить.
class UploadState {
  UploadState({
    required this.uploadId,
    required this.sizeBytes,
    required this.partSize,
    required this.partCount,
    required this.uploadedParts,
    required this.parts,
  });

  factory UploadState.fromJson(Map<String, dynamic> j) => UploadState(
        uploadId: j['upload_id'] as String,
        sizeBytes: (j['size_bytes'] as num).toInt(),
        partSize: (j['part_size'] as num).toInt(),
        partCount: (j['part_count'] as num).toInt(),
        uploadedParts: (j['uploaded_parts'] as List).cast<num>().map((n) => n.toInt()).toList(),
        parts: (j['parts'] as List)
            .map((p) => PartUrl((p['part_number'] as num).toInt(), p['url'] as String))
            .toList(),
      );

  final String uploadId;
  final int sizeBytes;
  final int partSize;
  final int partCount;
  final List<int> uploadedParts;
  final List<PartUrl> parts;
}

/// Экспорт листа (GET /projects/{id}/exports/{exportId}). [downloadUrl] есть только у готового.
class ExportJob {
  ExportJob({
    required this.id,
    required this.format,
    required this.status,
    this.error,
    this.downloadUrl,
    required this.filename,
    required this.createdAt,
  });

  factory ExportJob.fromJson(Map<String, dynamic> j) => ExportJob(
        id: j['id'] as String,
        format: j['format'] as String,
        status: j['status'] as String,
        error: j['error'] as String?,
        downloadUrl: j['download_url'] as String?,
        filename: j['filename'] as String,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );

  final String id;

  /// xlsx, docx или pdf.
  final String format;

  /// requested, completed или failed.
  final String status;
  final String? error;
  final String? downloadUrl;
  final String filename;
  final DateTime createdAt;

  bool get pending => status == 'requested';
}

/// Сообщение хаба "export": экспорт запрошен, готов или не удался.
class ExportUpdate {
  ExportUpdate({required this.exportId, required this.format, required this.status, this.error});

  factory ExportUpdate.fromJson(Map<String, dynamic> j) => ExportUpdate(
        exportId: j['export_id'] as String,
        format: j['format'] as String,
        status: j['status'] as String,
        error: j['error'] as String?,
      );

  final String exportId;
  final String format;
  final String status;
  final String? error;
}
