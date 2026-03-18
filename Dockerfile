FROM mcr.microsoft.com/dotnet/sdk:10.0

WORKDIR /app

# Create 8 class libraries to trigger parallel MSBuild
RUN dotnet new sln -n Repro && \
    for i in 1 2 3 4 5 6 7 8; do \
      dotnet new classlib -n Lib$i && \
      dotnet sln add Lib$i; \
    done && \
    dotnet restore

CMD ["dotnet", "build"]
