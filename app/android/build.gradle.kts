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
// compileSdk to the app's (37 if that can't be read). Only raised, never
// lowered, and preview SDKs are left alone.
subprojects {
    if (project.name != "app") {
        plugins.withId("com.android.library") {
            extensions
                .getByType(com.android.build.api.variant.LibraryAndroidComponentsExtension::class.java)
                .finalizeDsl { ext ->
                    val target =
                        rootProject
                            .findProject(":app")
                            ?.extensions
                            ?.findByType(com.android.build.api.dsl.ApplicationExtension::class.java)
                            ?.compileSdk ?: 37
                    if (ext.compileSdkPreview == null && (ext.compileSdk ?: 0) < target) {
                        ext.compileSdk = target
                    }
                }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
