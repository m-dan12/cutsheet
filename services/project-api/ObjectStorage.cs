using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;

namespace Cutsheet.ProjectApi;

/// <summary>
/// S3/MinIO. Два клиента: внутренний (minio:9000) для операций сервиса и публичный только для
/// подписи URL. Подпись включает хост, поэтому presigned URL должен быть выписан на адрес,
/// по которому к MinIO ходит клиент (S3:PublicEndpoint, по умолчанию localhost:9000).
/// </summary>
public sealed class ObjectStorage : IDisposable
{
    private readonly AmazonS3Client _internal;
    private readonly AmazonS3Client _public;
    private readonly bool _publicHttp;

    public ObjectStorage(IConfiguration config)
    {
        var endpoint = config["S3:Endpoint"] ?? "http://localhost:9000";
        var publicEndpoint = config["S3:PublicEndpoint"] ?? endpoint;
        var creds = new BasicAWSCredentials(config["S3:AccessKey"] ?? "cutsheet", config["S3:SecretKey"] ?? "cutsheet-secret");
        Bucket = config["S3:Bucket"] ?? "cutsheet";
        UrlLifetime = TimeSpan.FromMinutes(config.GetValue("S3:UrlMinutes", 60)); // FR-G2: ≤ 1 ч
        _internal = new AmazonS3Client(creds, Config(endpoint));
        _public = new AmazonS3Client(creds, Config(publicEndpoint));
        _publicHttp = publicEndpoint.StartsWith("http://", StringComparison.OrdinalIgnoreCase);
    }

    public string Bucket { get; }
    public TimeSpan UrlLifetime { get; }

    public static string Uri(string bucket, string key) => $"s3://{bucket}/{key}";

    public static (string Bucket, string Key) Parse(string uri)
    {
        if (!uri.StartsWith("s3://", StringComparison.Ordinal)) throw new ArgumentException($"not an s3 uri: {uri}");
        var rest = uri["s3://".Length..];
        var slash = rest.IndexOf('/');
        return (rest[..slash], rest[(slash + 1)..]);
    }

    public async Task<string> StartMultipart(string key, string contentType, CancellationToken ct) =>
        (await _internal.InitiateMultipartUploadAsync(new InitiateMultipartUploadRequest
        {
            BucketName = Bucket, Key = key, ContentType = contentType,
        }, ct)).UploadId;

    public string PresignPart(string key, string uploadId, int partNumber) =>
        _public.GetPreSignedURL(new GetPreSignedUrlRequest
        {
            BucketName = Bucket, Key = key, Verb = HttpVerb.PUT, UploadId = uploadId, PartNumber = partNumber,
            Expires = DateTime.UtcNow + UrlLifetime, Protocol = _publicHttp ? Protocol.HTTP : Protocol.HTTPS,
        });

    public string PresignGet(string uri)
    {
        var (bucket, key) = Parse(uri);
        return _public.GetPreSignedURL(new GetPreSignedUrlRequest
        {
            BucketName = bucket, Key = key, Verb = HttpVerb.GET,
            Expires = DateTime.UtcNow + UrlLifetime, Protocol = _publicHttp ? Protocol.HTTP : Protocol.HTTPS,
        });
    }

    /// <summary>Уже загруженные части multipart-загрузки (для докачки и завершения).</summary>
    public async Task<List<PartDetail>> ListParts(string key, string uploadId, CancellationToken ct)
    {
        var parts = new List<PartDetail>();
        int? marker = null;
        while (true)
        {
            var resp = await _internal.ListPartsAsync(new ListPartsRequest
            {
                BucketName = Bucket, Key = key, UploadId = uploadId,
                PartNumberMarker = marker?.ToString(),
            }, ct);
            if (resp.Parts is { } page) parts.AddRange(page);
            if (resp.IsTruncated != true) return parts;
            marker = resp.NextPartNumberMarker;
        }
    }

    public Task CompleteMultipart(string key, string uploadId, IEnumerable<PartDetail> parts, CancellationToken ct) =>
        _internal.CompleteMultipartUploadAsync(new CompleteMultipartUploadRequest
        {
            BucketName = Bucket, Key = key, UploadId = uploadId,
            PartETags = parts.OrderBy(p => p.PartNumber).Select(p => new PartETag(p.PartNumber ?? 0, p.ETag)).ToList(),
        }, ct);

    /// <summary>Размер объекта или null, если его нет (FR-G3: проверка перед публикацией события).</summary>
    public async Task<long?> ObjectSize(string key, CancellationToken ct)
    {
        try
        {
            return (await _internal.GetObjectMetadataAsync(Bucket, key, ct)).ContentLength;
        }
        catch (AmazonS3Exception e) when (e.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    private static AmazonS3Config Config(string endpoint) => new()
    {
        ServiceURL = endpoint,
        ForcePathStyle = true,
        AuthenticationRegion = "us-east-1",
        // MinIO и presigned PUT без лишних заголовков контрольных сумм.
        RequestChecksumCalculation = RequestChecksumCalculation.WHEN_REQUIRED,
        ResponseChecksumValidation = ResponseChecksumValidation.WHEN_REQUIRED,
    };

    public void Dispose()
    {
        _internal.Dispose();
        _public.Dispose();
    }
}
