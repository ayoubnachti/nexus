# The JAR is built and versioned by Maven before this image (through Nexus, see docs/adr/001-nexus.md):
#   CI:    Jenkins "Build images" stage, version 1.0.<build number>
#   Local: ./scripts/build-jars.sh
# The image only packages it, so image and published JAR are the same file.
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY target/*.jar app.jar

EXPOSE 8761
ENTRYPOINT ["java", "-jar", "app.jar"]