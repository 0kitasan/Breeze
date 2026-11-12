allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Gradle 9 移除了 Project.buildDir，统一改用 layout.buildDirectory（Provider API）
rootProject.layout.buildDirectory.set(file("../build"))
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.application") || plugins.hasPlugin("com.android.library")) {
            // AGP 9 移除了旧的 BaseExtension，改用统一的 CommonExtension DSL
            extensions.configure<com.android.build.api.dsl.CommonExtension> {
                compileSdk = 36
            }
        }
    }
}
subprojects {
    layout.buildDirectory.set(rootProject.layout.buildDirectory.dir(project.name))
}
subprojects {
    evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

apply(plugin = "com.github.ben-manes.versions") // 应用插件
