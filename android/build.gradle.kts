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
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            // Plugins ohne eigene NDK-Angabe (z. B. flutter_soloud) bekaemen sonst
            // das Standard-NDK des Android-Plugins statt des NDK der App. Folge:
            // beim ersten Bauen ein zweiter NDK-Download (~1 GB).
            val appNdk = rootProject.project(":app").extensions
                .findByType(com.android.build.api.dsl.ApplicationExtension::class.java)
                ?.ndkVersion
            if (appNdk != null) ndkVersion = appNdk
            defaultConfig {
                externalNativeBuild {
                    cmake {
                        arguments += "-DANDROID_STL=c++_shared"
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
