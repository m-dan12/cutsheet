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

class Scene {
  Scene({
    required this.id,
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.status,
    required this.keyframeUrls,
  });

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'] as String,
        index: (j['index'] as num).toInt(),
        startMs: (j['start_ms'] as num).toInt(),
        endMs: (j['end_ms'] as num).toInt(),
        status: j['status'] as String,
        keyframeUrls: (j['keyframe_urls'] as List).cast<String>(),
      );

  final String id;
  final int index;
  final int startMs;
  final int endMs;
  final String status;
  final List<String> keyframeUrls;
}

class SceneSheet {
  SceneSheet({this.fps, this.durationMs, required this.scenes});

  factory SceneSheet.fromJson(Map<String, dynamic> j) => SceneSheet(
        fps: (j['fps'] as num?)?.toDouble(),
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        scenes: (j['scenes'] as List).map((s) => Scene.fromJson(s as Map<String, dynamic>)).toList(),
      );

  final double? fps;
  final int? durationMs;
  final List<Scene> scenes;
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
