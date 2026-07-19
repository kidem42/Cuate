import Foundation

/// Self-contained localization for the ImageAddon (pattern: `LFL()` of
/// LayoutFix). Follows the app's current language, adds nothing to the
/// global `L()` table.
func IAL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = ImageAddonStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum ImageAddonStrings {
    static let table: [String: [AppLanguage: String]] = [
        "ia.tab": [.english: "Images", .spanish: "Imágenes", .russian: "Изображения"],

        // General tab master switch
        "ia.general.enable": [
            .english: "Image tools (beta)",
            .spanish: "Herramientas de imagen (beta)",
            .russian: "Инструменты изображений (бета)"
        ],
        "ia.general.enable.caption": [
            .english: "Process attached images in one click. Background removal and basic upscale run on-device — free and private, no key needed. Higher-quality upscale and object removal use cloud AI models (a fal.ai key, set in the Images tab).",
            .spanish: "Procesa las imágenes adjuntas en un clic. La eliminación de fondo y el escalado básico se ejecutan en el dispositivo — gratis y privados, sin clave. El escalado de mayor calidad y la eliminación de objetos usan modelos de IA en la nube (una clave de fal.ai, en la pestaña Imágenes).",
            .russian: "Обработка прикреплённых картинок в один клик. Удаление фона и базовый апскейл работают на устройстве — бесплатно и приватно, без ключа. Апскейл выше качеством и удаление объектов — облачные AI-модели (ключ fal.ai во вкладке «Изображения»)."
        ],

        // Settings tab intro
        "ia.header": [.english: "Image Tools", .spanish: "Herramientas de imagen", .russian: "Инструменты изображений"],
        "ia.footer": [
            .english: "Attach an image to the panel (paperclip button or ⌘V) and process it in one click. Background removal and basic (Lanczos) upscale run fully on-device — free and private. Higher-quality upscale, object removal, and the cloud background models use the fal.ai API — one key covers them; images are sent directly to the provider and never stored elsewhere.",
            .spanish: "Adjunta una imagen al panel (botón de clip o ⌘V) y procésala en un clic. La eliminación de fondo y el escalado básico (Lanczos) se ejecutan por completo en el dispositivo — gratis y privados. El escalado de mayor calidad, la eliminación de objetos y los modelos de fondo en la nube usan la API de fal.ai — una clave los cubre; las imágenes van directas al proveedor y no se guardan en ningún otro sitio.",
            .russian: "Прикрепите картинку в панель (кнопка-скрепка или ⌘V) и обработайте её в один клик. Удаление фона и базовый апскейл (Lanczos) работают полностью на устройстве — бесплатно и приватно. Апскейл выше качеством, удаление объектов и облачные модели фона идут через API fal.ai — один ключ закрывает их; изображения отправляются напрямую провайдеру и нигде больше не хранятся."
        ],

        // API key section
        "ia.keys.header": [.english: "fal.ai API Key", .spanish: "Clave API de fal.ai", .russian: "API-ключ fal.ai"],
        "ia.keys.footer": [
            .english: "The key is stored in the macOS Keychain, never in files.",
            .spanish: "La clave se guarda en el Llavero de macOS, nunca en archivos.",
            .russian: "Ключ хранится в Связке ключей macOS, а не в файлах."
        ],

        // Function sections
        "ia.upscale.header": [.english: "Upscale", .spanish: "Escalado", .russian: "Апскейл"],
        "ia.bg.header": [.english: "Background Removal", .spanish: "Eliminación de fondo", .russian: "Удаление фона"],
        "ia.cleanup.header": [.english: "Object Removal", .spanish: "Eliminación de objetos", .russian: "Удаление объектов"],
        "ia.cleanup.footer": [
            .english: "Removes unwanted objects, text, and defects. Brush mode uses the selected model; the text mode («describe what to remove») always runs through the smart model below.",
            .spanish: "Elimina objetos, textos y defectos no deseados. El modo pincel usa el modelo seleccionado; el modo texto («describe qué eliminar») siempre usa el modelo inteligente de abajo.",
            .russian: "Удаляет лишние объекты, надписи, дефекты. Режим кисти использует выбранную модель; текстовый режим («опишите, что удалить») всегда работает через умную модель ниже."
        ],
        "ia.model": [.english: "Model", .spanish: "Modelo", .russian: "Модель"],

        // Model captions (ТЗ §3.1a)
        "ia.model.recraftCrisp.caption": [
            .english: "Fast and clean, no hallucinated details. Best default choice",
            .spanish: "Rápido y limpio, sin detalles inventados. La mejor opción por defecto",
            .russian: "Быстро и чисто, без «дорисовок». Лучший выбор по умолчанию"
        ],
        "ia.model.topaz.caption": [
            .english: "Top photo quality, huge resolutions (up to 512 MP)",
            .spanish: "Máxima calidad fotográfica, resoluciones enormes (hasta 512 MP)",
            .russian: "Максимальное качество фото, огромные разрешения (до 512 МП)"
        ],
        "ia.model.seedvr.caption": [
            .english: "Community favorite for quality; slower, best for tricky photos",
            .spanish: "Preferido de la comunidad por calidad; más lento, ideal para fotos difíciles",
            .russian: "Топ по мнению сообщества; медленнее, лучше для сложных фото"
        ],
        "ia.model.esrgan.caption": [
            .english: "The cheapest one — fine for simple pictures",
            .spanish: "El más barato — suficiente para imágenes simples",
            .russian: "Самый дешёвый, годится для простых картинок"
        ],
        "ia.model.rmbg.caption": [
            .english: "Precise edges, safe for commercial use",
            .spanish: "Bordes precisos, seguro para uso comercial",
            .russian: "Точные края, безопасна для коммерческого использования"
        ],
        "ia.model.birefnet.caption": [
            .english: "Open SOTA model, nearly free",
            .spanish: "Modelo SOTA abierto, casi gratis",
            .russian: "Открытая SOTA-модель, почти бесплатно"
        ],
        "ia.model.appleBg.caption": [
            .english: "On-device and free — no key, nothing leaves your Mac. Great for people, pets and clear subjects",
            .spanish: "En el dispositivo y gratis — sin clave, nada sale de tu Mac. Ideal para personas, mascotas y sujetos nítidos",
            .russian: "На устройстве и бесплатно — без ключа, ничего не покидает Mac. Отлично для людей, животных и чётких объектов"
        ],
        "ia.model.appleUpscale.caption": [
            .english: "On-device and free. Fast Lanczos resampling — sharper edges, but no AI-invented detail. For photo-quality, pick a cloud model",
            .spanish: "En el dispositivo y gratis. Reescalado Lanczos rápido — bordes más nítidos, pero sin detalle inventado por IA. Para calidad fotográfica, elige un modelo en la nube",
            .russian: "На устройстве и бесплатно. Быстрый ресемплинг (Lanczos) — края чётче, но новых деталей не появляется. Для фото-качества выберите облачную модель"
        ],
        "ia.model.briaEraser.caption": [
            .english: "Careful removal by selection (brush mask)",
            .spanish: "Eliminación cuidadosa por selección (máscara de pincel)",
            .russian: "Аккуратное удаление по выделению (маске)"
        ],
        "ia.model.objectRemoval.caption": [
            .english: "Describe in text what to remove — no selection needed",
            .spanish: "Describe en texto qué eliminar — sin selección",
            .russian: "Опишите текстом, что удалить — без выделения"
        ],

        // Model tier badges (fixed enum, ТЗ §3.1a)
        "ia.tier.onDevice": [.english: "On-device", .spanish: "En el dispositivo", .russian: "На устройстве"],
        "ia.tier.budget": [.english: "Budget", .spanish: "Económico", .russian: "Бюджет"],
        "ia.tier.standard": [.english: "Standard", .spanish: "Estándar", .russian: "Стандарт"],
        "ia.tier.quality": [.english: "Quality", .spanish: "Calidad", .russian: "Качество"],
        "ia.tier.premium": [.english: "Premium", .spanish: "Premium", .russian: "Премиум"],
        "ia.tier.smart": [.english: "Smart", .spanish: "Inteligente", .russian: "Умный"],
        "ia.tier.freedom": [.english: "Freedom", .spanish: "Libertad", .russian: "Свобода"],
        "ia.price.free": [.english: "Free", .spanish: "Gratis", .russian: "Бесплатно"],

        // Saving
        "ia.save.header": [.english: "Saving", .spanish: "Guardado", .russian: "Сохранение"],
        "ia.save.folder": [.english: "Save results to", .spanish: "Guardar resultados en", .russian: "Папка результатов"],
        "ia.save.choose": [.english: "Choose…", .spanish: "Elegir…", .russian: "Выбрать…"],
        "ia.save.reset": [.english: "Reset", .spanish: "Restablecer", .russian: "Сбросить"],
        "ia.save.downloads": [.english: "Downloads (default)", .spanish: "Descargas (por defecto)", .russian: "Загрузки (по умолчанию)"],
        "ia.save.footer": [
            .english: "The Save button under a result writes the file here without any dialogs.",
            .spanish: "El botón Guardar bajo un resultado escribe el archivo aquí sin diálogos.",
            .russian: "Кнопка «Сохранить» под результатом пишет файл сюда без диалогов."
        ],

        // Spending
        "ia.spend.header": [.english: "Spending", .spanish: "Gasto", .russian: "Расходы"],
        "ia.spend.session": [.english: "This session", .spanish: "Esta sesión", .russian: "За сессию"],
        "ia.spend.month": [.english: "This month", .spanish: "Este mes", .russian: "За месяц"],
        "ia.spend.footer": [
            .english: "Estimated from catalog prices; stored only on this Mac.",
            .spanish: "Estimado según los precios del catálogo; se guarda solo en este Mac.",
            .russian: "Оценка по ценам каталога; хранится только на этом Mac."
        ],

        // Attachment actions bar
        "ia.action.upscale": [.english: "Upscale", .spanish: "Escalar", .russian: "Апскейл"],
        "ia.action.removeBg": [.english: "Remove BG", .spanish: "Quitar fondo", .russian: "Убрать фон"],
        "ia.action.cleanup": [.english: "Remove Objects", .spanish: "Quitar objetos", .russian: "Удалить объекты"],
        "ia.action.faceEnhance": [.english: "Enhance faces", .spanish: "Mejorar rostros", .russian: "Улучшить лица"],
        "ia.action.factorMax": [.english: "max", .spanish: "máx", .russian: "макс"],
        // Function tooltips: what it does · model (price) · slash alternative
        "ia.help.upscale": [
            .english: "Increase the image resolution and detail.\nModel: %@ (%@). The ▾ menu picks the factor.\nAlso: type /upscale in the input field",
            .spanish: "Aumenta la resolución y el detalle de la imagen.\nModelo: %@ (%@). El menú ▾ elige el factor.\nTambién: escribe /upscale en el campo de entrada",
            .russian: "Увеличивает разрешение и детализацию картинки.\nМодель: %@ (%@). Меню ▾ — выбор кратности.\nАльтернатива: команда /upscale в поле ввода"
        ],
        "ia.help.removeBg": [
            .english: "Remove the background — the result is a PNG with transparency.\nModel: %@ (%@).\nAlso: type /bg in the input field",
            .spanish: "Elimina el fondo — el resultado es un PNG con transparencia.\nModelo: %@ (%@).\nTambién: escribe /bg en el campo de entrada",
            .russian: "Удаляет фон — результат PNG с прозрачностью.\nМодель: %@ (%@).\nАльтернатива: команда /bg в поле ввода"
        ],
        "ia.help.cleanup": [
            .english: "Remove unwanted objects, text or defects: paint them with a brush or describe them in words.\nModel: %@ (%@).\nAlso: /cleanup <what to remove>",
            .spanish: "Elimina objetos, textos o defectos no deseados: píntalos con el pincel o descríbelos con palabras.\nModelo: %@ (%@).\nTambién: /cleanup <qué eliminar>",
            .russian: "Удаляет лишние объекты, надписи, дефекты: закрасьте их кистью или опишите словами.\nМодель: %@ (%@).\nАльтернатива: /cleanup <что удалить>"
        ],
        "ia.action.upscale.help": [
            .english: "Run with %@ (%@)",
            .spanish: "Ejecutar con %@ (%@)",
            .russian: "Выполнить: %@ (%@)"
        ],
        "ia.action.needKey": [
            .english: "Image operations need a fal.ai API key.",
            .spanish: "Las operaciones de imagen necesitan una clave API de fal.ai.",
            .russian: "Для операций с изображениями нужен API-ключ fal.ai."
        ],
        "ia.action.openSettings": [.english: "Open Settings", .spanish: "Abrir ajustes", .russian: "Открыть настройки"],

        // Progress & results
        "ia.status.upscaling": [.english: "Upscaling — %@…", .spanish: "Escalando — %@…", .russian: "Апскейл — %@…"],
        "ia.status.removingBg": [.english: "Removing background — %@…", .spanish: "Quitando el fondo — %@…", .russian: "Убираем фон — %@…"],
        "ia.status.cleaning": [.english: "Removing objects — %@…", .spanish: "Quitando objetos — %@…", .russian: "Удаляем объекты — %@…"],
        "ia.status.cancelledMsg": [.english: "Operation cancelled.", .spanish: "Operación cancelada.", .russian: "Операция отменена."],
        "ia.cancel.help": [.english: "Cancel the image operation", .spanish: "Cancelar la operación de imagen", .russian: "Отменить операцию с изображением"],
        "ia.result.upscaled": [.english: "Upscaled with %@", .spanish: "Escalado con %@", .russian: "Апскейл: %@"],
        "ia.result.nobg": [.english: "Background removed with %@", .spanish: "Fondo eliminado con %@", .russian: "Фон удалён: %@"],
        "ia.result.cleaned": [.english: "Objects removed with %@", .spanish: "Objetos eliminados con %@", .russian: "Объекты удалены: %@"],
        "ia.result.retryOther": [.english: "Retry with another model", .spanish: "Repetir con otro modelo", .russian: "Повторить с другой моделью"],
        "ia.result.continueEditing": [.english: "Continue editing", .spanish: "Seguir editando", .russian: "Продолжить редактирование"],

        // Input notes ("плашки")
        "ia.note.gif": [
            .english: "GIF: only the first frame is processed.",
            .spanish: "GIF: solo se procesa el primer fotograma.",
            .russian: "GIF: обрабатывается только первый кадр."
        ],
        "ia.note.downscaled": [
            .english: "The image was downscaled from %.0f to %.0f MP (input limit).",
            .spanish: "La imagen se redujo de %.0f a %.0f MP (límite de entrada).",
            .russian: "Изображение уменьшено с %.0f до %.0f МП (лимит входа)."
        ],

        // Result bar tooltips
        "ia.help.save": [
            .english: "Save to “%@” — no dialogs. The folder is set in Settings → Images",
            .spanish: "Guardar en “%@” — sin diálogos. La carpeta se elige en Ajustes → Imágenes",
            .russian: "Сохранить в «%@» — без диалогов. Папка меняется в Настройках → «Изображения»"
        ],
        "ia.help.reveal": [
            .english: "Show the saved file in Finder",
            .spanish: "Mostrar el archivo guardado en Finder",
            .russian: "Показать сохранённый файл в Finder"
        ],
        "ia.help.copy": [
            .english: "Copy the image to the clipboard",
            .spanish: "Copiar la imagen al portapapeles",
            .russian: "Копировать изображение в буфер обмена"
        ],
        "ia.help.retryOther": [
            .english: "Run the same operation on the original with a different model — handy for comparing quality",
            .spanish: "Repite la misma operación sobre el original con otro modelo — útil para comparar calidad",
            .russian: "Повторить ту же операцию над исходником другой моделью — удобно сравнить качество"
        ],
        "ia.help.continueEditing": [
            .english: "Attach this result as the new input and keep removing objects",
            .spanish: "Adjunta este resultado como nueva entrada y sigue eliminando objetos",
            .russian: "Сделать этот результат новым вложением и продолжить удаление объектов"
        ],

        // Mask editor
        "ia.cleanup.brush": [.english: "Brush", .spanish: "Pincel", .russian: "Кисть"],
        "ia.cleanup.text": [.english: "By text", .spanish: "Por texto", .russian: "Текстом"],
        "ia.help.brushMode": [
            .english: "Paint a mask over the areas to remove",
            .spanish: "Pinta una máscara sobre las zonas a eliminar",
            .russian: "Закрасьте маской области, которые нужно удалить"
        ],
        "ia.help.textMode": [
            .english: "Describe the object in words — no painting needed (smart model)",
            .spanish: "Describe el objeto con palabras — sin pintar (modelo inteligente)",
            .russian: "Опишите объект словами — без закрашивания (умная модель)"
        ],
        "ia.help.brushSize": [
            .english: "Brush diameter in image pixels",
            .spanish: "Diámetro del pincel en píxeles de la imagen",
            .russian: "Диаметр кисти в пикселях изображения"
        ],
        "ia.help.undo": [
            .english: "Remove the last stroke",
            .spanish: "Eliminar el último trazo",
            .russian: "Убрать последний мазок"
        ],
        "ia.help.clear": [
            .english: "Clear the whole mask",
            .spanish: "Borrar toda la máscara",
            .russian: "Стереть всю маску"
        ],
        "ia.help.applyMask": [
            .english: "Remove everything painted over",
            .spanish: "Eliminar todo lo pintado",
            .russian: "Удалить всё закрашенное"
        ],
        "ia.help.applyText": [
            .english: "Remove what the description matches",
            .spanish: "Eliminar lo que coincida con la descripción",
            .russian: "Удалить то, что подходит под описание"
        ],
        "ia.cleanup.hint": [
            .english: "Paint over what you want removed",
            .spanish: "Pinta sobre lo que quieras eliminar",
            .russian: "Закрасьте то, что нужно удалить"
        ],
        "ia.cleanup.brushSize": [.english: "Brush size", .spanish: "Tamaño del pincel", .russian: "Размер кисти"],
        "ia.cleanup.undo": [.english: "Undo", .spanish: "Deshacer", .russian: "Отменить"],
        "ia.cleanup.clear": [.english: "Reset", .spanish: "Restablecer", .russian: "Сбросить"],
        "ia.cleanup.apply": [.english: "Apply", .spanish: "Aplicar", .russian: "Применить"],
        "ia.cleanup.close": [.english: "Close", .spanish: "Cerrar", .russian: "Закрыть"],
        "ia.cleanup.prompt.placeholder": [
            .english: "What to remove? E.g. “wires in the background”",
            .spanish: "¿Qué eliminar? P. ej., “cables en el fondo”",
            .russian: "Что удалить? Например: «провода на фоне»"
        ],

        // Slash commands
        "ia.slash.needAttachment": [
            .english: "This command works on an attached image — attach one first (paperclip or ⌘V).",
            .spanish: "Este comando actúa sobre una imagen adjunta — adjúntala primero (clip o ⌘V).",
            .russian: "Команда действует на прикреплённую картинку — сначала прикрепите её (скрепка или ⌘V)."
        ],
        "ia.slash.cleanupNeedsText": [
            .english: "Add a description: /cleanup wires in the background (or use the button with the brush).",
            .spanish: "Añade una descripción: /cleanup cables en el fondo (o usa el botón con el pincel).",
            .russian: "Добавьте описание: /cleanup провода на фоне (или используйте кнопку с кистью)."
        ],

        // Options
        "ia.options.header": [.english: "Options", .spanish: "Opciones", .russian: "Опции"],
        "ia.options.outputFormat": [.english: "Result format", .spanish: "Formato del resultado", .russian: "Формат результата"],
        "ia.options.autoCopy": [
            .english: "Copy results to the clipboard automatically",
            .spanish: "Copiar los resultados al portapapeles automáticamente",
            .russian: "Автоматически копировать результат в буфер обмена"
        ],
        "ia.options.maxInput": [.english: "Input size limit", .spanish: "Límite de tamaño de entrada", .russian: "Лимит размера входа"],
        "ia.options.mp": [.english: "%d MP", .spanish: "%d MP", .russian: "%d МП"],
        "ia.options.footer": [
            .english: "Background removal always outputs PNG (transparency). Larger inputs are downscaled to the limit with a notice; files over 20 MB are downscaled too.",
            .spanish: "La eliminación de fondo siempre produce PNG (transparencia). Las entradas mayores se reducen al límite con un aviso; los archivos de más de 20 MB también se reducen.",
            .russian: "Удаление фона всегда отдаёт PNG (прозрачность). Вход больше лимита уменьшается с предупреждением; файлы больше 20 МБ — тоже."
        ],
        "ia.result.save": [.english: "Save", .spanish: "Guardar", .russian: "Сохранить"],
        "ia.result.saved": [.english: "Saved", .spanish: "Guardado", .russian: "Сохранено"],
        "ia.result.reveal": [.english: "Show in Finder", .spanish: "Mostrar en Finder", .russian: "Показать в Finder"],
        "ia.result.copy": [.english: "Copy", .spanish: "Copiar", .russian: "Копировать"],
        "ia.result.copied": [.english: "Copied", .spanish: "Copiado", .russian: "Скопировано"],

        // Errors
        "ia.error.missingKey": [
            .english: "No fal.ai API key. Add one in Settings → Images.",
            .spanish: "No hay clave API de fal.ai. Añádela en Ajustes → Imágenes.",
            .russian: "Нет API-ключа fal.ai. Добавьте его в Настройках → «Изображения»."
        ],
        "ia.error.unreadableInput": [
            .english: "The file could not be read as an image.",
            .spanish: "No se pudo leer el archivo como imagen.",
            .russian: "Не удалось прочитать файл как изображение."
        ],
        "ia.error.busy": [
            .english: "Another image operation is still running.",
            .spanish: "Otra operación de imagen sigue en curso.",
            .russian: "Другая операция с изображением ещё выполняется."
        ],
        "ia.error.contentFiltered": [
            .english: "The model declined this image. Try a different model.",
            .spanish: "El modelo rechazó esta imagen. Prueba con otro modelo.",
            .russian: "Модель отклонила изображение. Попробуйте другую модель."
        ],
        "ia.error.http": [
            .english: "Image API error (HTTP %d): %@",
            .spanish: "Error de la API de imágenes (HTTP %d): %@",
            .russian: "Ошибка API изображений (HTTP %d): %@"
        ],
        "ia.error.timeout": [
            .english: "The operation timed out. Try again.",
            .spanish: "La operación agotó el tiempo de espera. Inténtalo de nuevo.",
            .russian: "Время ожидания операции истекло. Попробуйте ещё раз."
        ],
        "ia.error.badResponse": [
            .english: "Unexpected response from the image service.",
            .spanish: "Respuesta inesperada del servicio de imágenes.",
            .russian: "Неожиданный ответ сервиса изображений."
        ],
        "ia.error.noSubject": [
            .english: "No clear subject found to separate from the background. For tricky images, pick a cloud model (Bria / BiRefNet) under Background Removal in Settings → Images.",
            .spanish: "No se encontró un sujeto claro para separar del fondo. Para imágenes difíciles, elige un modelo en la nube (Bria / BiRefNet) en Ajustes → Imágenes.",
            .russian: "Не найден чёткий объект для отделения от фона. Для сложных изображений выберите облачную модель (Bria / BiRefNet) в разделе «Удаление фона» в Настройках → «Изображения»."
        ],
        "ia.error.saveFailed": [
            .english: "Couldn't save the file: %@",
            .spanish: "No se pudo guardar el archivo: %@",
            .russian: "Не удалось сохранить файл: %@"
        ]
    ]
}
