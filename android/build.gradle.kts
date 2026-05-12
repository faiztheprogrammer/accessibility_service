allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val rootBuildDir = File(rootProject.projectDir, "../build")
rootProject.layout.buildDirectory.set(rootBuildDir)

subprojects {
    project.layout.buildDirectory.set(File(rootBuildDir, project.name))
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}