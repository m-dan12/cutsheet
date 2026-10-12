# Сборка из корня репозитория: docker build -f services/project-api/Dockerfile .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY libs/dotnet/Cutsheet.Messaging/Cutsheet.Messaging.csproj libs/dotnet/Cutsheet.Messaging/
COPY services/project-api/ProjectApi.csproj services/project-api/
RUN dotnet restore services/project-api/ProjectApi.csproj
COPY libs/dotnet/ libs/dotnet/
COPY services/project-api/ services/project-api/
RUN dotnet publish services/project-api/ProjectApi.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out .
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
USER app
ENTRYPOINT ["dotnet", "ProjectApi.dll"]
