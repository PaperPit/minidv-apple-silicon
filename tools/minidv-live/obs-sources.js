#!/usr/bin/env node
//
//  obs-sources.js — приводит текущую сцену OBS к рабочему виду:
//  добавляет Syphon-источник с камеры и аудиовход BlackHole, вписывает видео в канву.
//  Идемпотентно: если источники уже есть, они только перенастраиваются.
//
//  Работает через obs-websocket (OBS 28+, порт 4455). Пароль берётся из конфига OBS.
//

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const CONFIG = path.join(
  os.homedir(),
  'Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json'
);
const VIDEO_NAME = 'Sony DCR-PC115E';
const AUDIO_NAME = 'BlackHole 2ch';
const SYPHON_SERVER = 'Sony DCR-PC115E';
const DEVICE_HINT = 'BlackHole';
const TIMEOUT_MS = 15000;

const log = (...args) => console.log('[obs-sources]', ...args);

let config;
try {
  config = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
} catch (error) {
  log('не читается конфиг obs-websocket:', error.message);
  process.exit(2);
}
if (!config.server_enabled) {
  log('WebSocket-сервер OBS выключен (server_enabled=false)');
  process.exit(3);
}

const port = config.server_port || 4455;
const password = config.server_password || '';

const pending = new Map();
let counter = 1;
let finished = false;

const socket = new WebSocket(`ws://127.0.0.1:${port}`);
const timer = setTimeout(() => {
  log('таймаут: OBS не ответил');
  process.exit(4);
}, TIMEOUT_MS);

function request(requestType, requestData = {}) {
  const requestId = String(counter++);
  return new Promise((resolve, reject) => {
    pending.set(requestId, { resolve, reject });
    socket.send(JSON.stringify({ op: 6, d: { requestType, requestId, requestData } }));
  });
}

function authString(challenge, salt) {
  const secret = crypto.createHash('sha256').update(password + salt).digest('base64');
  return crypto.createHash('sha256').update(secret + challenge).digest('base64');
}

socket.onerror = () => {
  log('нет связи с obs-websocket (сервер выключен или OBS не запущен)');
  clearTimeout(timer);
  process.exit(5);
};

socket.onmessage = async (event) => {
  const message = JSON.parse(event.data);

  if (message.op === 0) { // Hello
    const payload = { rpcVersion: 1, eventSubscriptions: 0 };
    if (message.d.authentication) {
      payload.authentication = authString(message.d.authentication.challenge, message.d.authentication.salt);
    }
    socket.send(JSON.stringify({ op: 1, d: payload }));
    return;
  }

  if (message.op === 2) { // Identified
    try {
      await syncScene();
      clearTimeout(timer);
      finished = true;
      socket.close();
      process.exit(0);
    } catch (error) {
      log('ОШИБКА:', error.message);
      clearTimeout(timer);
      process.exit(6);
    }
    return;
  }

  if (message.op === 7) { // RequestResponse
    const { requestId, requestStatus, responseData } = message.d;
    const entry = pending.get(requestId);
    if (!entry) return;
    pending.delete(requestId);
    if (requestStatus && requestStatus.result === false) {
      entry.reject(new Error(`${requestStatus.code}: ${requestStatus.comment}`));
    } else {
      entry.resolve(responseData || {});
    }
  }
};

socket.onclose = () => {
  if (!finished) {
    log('соединение закрыто до завершения');
    process.exit(7);
  }
};

async function inputList() {
  const data = await request('GetInputList');
  return data.inputs || [];
}

async function createInput(name, kind, sceneName, settings) {
  const payload = {
    inputName: name,
    inputKind: kind,
    sceneName,
    inputSettings: settings,
    sceneItemEnabled: true,
  };
  try {
    await request('CreateInput', payload);
  } catch (error) {
    // Старые сборки obs-websocket не знают sceneItemEnabled.
    delete payload.sceneItemEnabled;
    await request('CreateInput', payload);
  }
}

async function syncScene() {
  const scenes = await request('GetSceneList');
  const sceneName = scenes.currentProgramSceneName
    || (scenes.scenes && scenes.scenes[0] && scenes.scenes[0].sceneName);
  if (!sceneName) throw new Error('в OBS нет ни одной сцены');
  log('текущая сцена:', sceneName);

  let inputs = await inputList();

  // --- Видео: Syphon-клиент -------------------------------------------------
  if (!inputs.some((i) => i.inputName === VIDEO_NAME)) {
    await createInput(VIDEO_NAME, 'syphon-input', sceneName, {});
    log('создан источник видео:', VIDEO_NAME);
    inputs = await inputList();
  } else {
    log('источник видео уже есть:', VIDEO_NAME);
  }

  // Syphon-сервер выбирается по uuid, а когда uuid сменился (новый запуск ASFW) —
  // по паре name+app_name. Прописываем все три поля, иначе источник остаётся чёрным.
  // После перезапуска ASFW каталог Syphon какое-то время держит и старое
  // объявление сервера, поэтому ждём и берём самое свежее совпадение.
  let server = null;
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const servers = await request('GetInputPropertiesListPropertyItems', {
      inputName: VIDEO_NAME,
      propertyName: 'uuid',
    });
    const matches = (servers.propertyItems || []).filter(
      (p) => (p.itemName || '').includes(SYPHON_SERVER) && p.itemValue
    );
    if (matches.length) {
      server = matches[matches.length - 1];
      if (matches.length > 1) {
        log(`видео: видно ${matches.length} сервера с этим именем — беру самый свежий`);
      }
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if (!server) {
    log(`Syphon-сервер «${SYPHON_SERVER}» не найден — живой режим ASFW не запущен?`);
  } else {
    const parsed = /^\[(.+?)\]\s*(.*)$/.exec(server.itemName);
    const appName = parsed ? parsed[1] : 'ASFW';
    const serverName = parsed ? parsed[2] : SYPHON_SERVER;
    const current = await request('GetInputSettings', { inputName: VIDEO_NAME });
    const settings = current.inputSettings || {};
    if (settings.uuid !== server.itemValue || settings.name !== serverName || settings.app_name !== appName) {
      await request('SetInputSettings', {
        inputName: VIDEO_NAME,
        inputSettings: { uuid: server.itemValue, name: serverName, app_name: appName },
        overlay: true,
      });
      log(`видео: сервер «${appName} / ${serverName}» выбран явно`);
    } else {
      log('видео: сервер уже выбран');
    }
  }

  const video = await request('GetVideoSettings');
  const items = await request('GetSceneItemList', { sceneName });
  const item = (items.sceneItems || []).find((i) => i.sourceName === VIDEO_NAME);
  if (item) {
    await request('SetSceneItemTransform', {
      sceneName,
      sceneItemId: item.sceneItemId,
      sceneItemTransform: {
        boundsType: 'OBS_BOUNDS_SCALE_INNER',
        boundsAlignment: 0,
        boundsWidth: video.baseWidth || 1920,
        boundsHeight: video.baseHeight || 1080,
        positionX: 0,
        positionY: 0,
        alignment: 5,
      },
    });
    log(`видео: вписано в канву ${video.baseWidth}x${video.baseHeight}`);
  }

  // --- Звук: вход BlackHole -------------------------------------------------
  inputs = await inputList();
  if (!inputs.some((i) => i.inputName === AUDIO_NAME)) {
    await createInput(AUDIO_NAME, 'coreaudio_input_capture', sceneName, {});
    log('создан источник звука:', AUDIO_NAME);
    inputs = await inputList();
  } else {
    log('источник звука уже есть:', AUDIO_NAME);
  }

  const audioSettings = await request('GetInputSettings', { inputName: AUDIO_NAME });
  const currentDevice = (audioSettings.inputSettings || {}).device_id;
  if (typeof currentDevice === 'string' && currentDevice.toLowerCase().includes(DEVICE_HINT.toLowerCase())) {
    log('звук: устройство уже выбрано —', currentDevice);
  } else {
    const property = await request('GetInputPropertiesListPropertyItems', {
      inputName: AUDIO_NAME,
      propertyName: 'device_id',
    });
    const device = (property.propertyItems || []).find(
      (p) => (p.itemName || '').toLowerCase().includes(DEVICE_HINT.toLowerCase())
    );
    if (device) {
      await request('SetInputSettings', {
        inputName: AUDIO_NAME,
        inputSettings: { device_id: device.itemValue },
        overlay: true,
      });
      log(`звук: устройство = ${device.itemName} (${device.itemValue})`);
    } else {
      log('звук: в списке устройств OBS нет BlackHole — выберите вручную');
    }
  }

  // --- Виртуальная камера ---------------------------------------------------
  // Расширение OBS Virtual Camera видно в списке устройств всегда, даже когда
  // OBS закрыт, но кадры идут только при включённом выходе. Поэтому включаем.
  if (process.env.MINIDV_NO_VIRTUALS === '1') {
    log('виртуальная камера: пропущена (MINIDV_NO_VIRTUALS=1)');
  } else {
    const status = await request('GetVirtualCamStatus').catch(() => null);
    if (status && status.outputActive) {
      log('виртуальная камера уже включена');
    } else {
      try {
        await request('StartVirtualCam');
        log('виртуальная камера включена (OBS Virtual Camera)');
      } catch (error) {
        log('виртуальную камеру включить не удалось:', error.message);
      }
    }
  }

  const final = await inputList();
  log('источники сцены: ' + final.map((i) => `${i.inputName} [${i.inputKind}]`).join(', '));
}
