subprojects {
    repositories {
        google()
        mavenCentral()
    }
    
    val newSubprojectBuildDir: Directory = rootProject.layout.buildDirectory   
        .dir("../../build/${project.name}")
        .get()
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    project.evaluationDependsOn(":app")
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
