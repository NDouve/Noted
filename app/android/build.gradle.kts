allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some transitive plugins (for example keyboard_height_plugin, via
// appflowy_editor) compile against an old SDK, which fails the AAR metadata
// check of newer AndroidX dependencies. We can't patch them, so raise their
// compileSdk to the app's. Only raised, never lowered.
subprojects {
    if (project.name != "app") {
        plugins.withId("com.android.library") {
            val raiseCompileSdk = {
                val android = extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)
                val current = android?.compileSdk
                if (android != null && (current == null || current < 36)) {
                    android.compileSdk = 36
                }
            }
            if (project.state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
