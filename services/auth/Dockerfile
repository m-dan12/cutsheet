# Сборка из корня репозитория: docker build -f services/auth/Dockerfile .
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY libs/dotnet/Cutsheet.Messaging/Cutsheet.Messaging.csproj libs/dotnet/Cutsheet.Messaging/
COPY services/auth/Auth.csproj services/auth/
RUN dotnet restore services/auth/Auth.csproj
COPY libs/dotnet/ libs/dotnet/
COPY services/auth/ services/auth/
RUN dotnet publish services/auth/Auth.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out .
# Каталог ключа подписи JWT: том auth-keys наследует владельца app при первом монтировании.
RUN mkdir /keys && chown app /keys
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
USER app
ENTRYPOINT ["dotnet", "Auth.dll"]
