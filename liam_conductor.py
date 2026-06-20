import asyncio
import aiohttp
import re
import json
import time
import os
import signal
import sys
import logging
import subprocess
from collections import deque, defaultdict
from typing import Optional, Dict
from dotenv import load_dotenv

# Disable ChromaDB telemetry
os.environ["ANONYMIZED_TELEMETRY"] = "false"
os.environ["CHROMA_SERVER_HOST"] = "localhost"
os.environ["CHROMA_SERVER_HTTP_PORT"] = "8000"

from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes
import chromadb
from chromadb.config import Settings
from sentence_transformers import SentenceTransformer

# ========== ЗАГРУЗКА .ENV ==========
load_dotenv()

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "ТВОЙ_ТОКЕН")
SERVER_8B_URL = os.getenv("SERVER_8B_URL", "http://10.0.9.118:11434/api/generate")
SERVER_8B_MODEL = os.getenv("SERVER_8B_MODEL", "hf.co/bartowski/L3-8B-Stheno-v3.2-GGUF:Q6_K")
QWEN_HELPER_ENABLED = os.getenv("QWEN_HELPER_ENABLED", "false").lower() in ("1", "true", "yes")
QWEN_HELPER_MODEL = os.getenv("QWEN_HELPER_MODEL", "qwen2.5:7b")
QWEN_HELPER_URL = os.getenv("QWEN_HELPER_URL", "http://localhost:11434/api/generate")
QWEN_HELPER_TIMEOUT = int(os.getenv("QWEN_HELPER_TIMEOUT", "3"))

BUFFER_SIZE = int(os.getenv("BUFFER_SIZE", "30"))
EMOTION_DECAY = float(os.getenv("EMOTION_DECAY", "0.95"))
RAG_COLLECTION_NAME = os.getenv("RAG_COLLECTION_NAME", "liam_memories")
RAG_SIMILARITY_THRESHOLD = float(os.getenv("RAG_SIMILARITY_THRESHOLD", "0.6"))
RAG_TOP_K = int(os.getenv("RAG_TOP_K", "3"))
SUMMARY_BASE_INTERVAL = int(os.getenv("SUMMARY_BASE_INTERVAL", "25"))
TIMEOUT = int(os.getenv("TIMEOUT", "45"))
CLEANUP_INTERVAL_HOURS = int(os.getenv("CLEANUP_INTERVAL_HOURS", "24"))
MEMORY_MIN_AGE_DAYS = int(os.getenv("MEMORY_MIN_AGE_DAYS", "30"))

# Lore database settings
LORE_DB_PATH = os.getenv("LORE_DB_PATH", "./chroma_db")
LORE_COLLECTION_NAME = os.getenv("LORE_COLLECTION_NAME", "world_lore")
LORE_ENABLED = os.getenv("LORE_ENABLED", "true").lower() in ("1", "true", "yes")
LORE_TOP_K = int(os.getenv("LORE_TOP_K", "3"))
LORE_SIMILARITY_THRESHOLD = float(os.getenv("LORE_SIMILARITY_THRESHOLD", "0.6"))
LORE_USE_SUMMARY = os.getenv("LORE_USE_SUMMARY", "true").lower() in ("1", "true", "yes")

TRIGGER_WORDS = ["запомни", "важно", "запомнить", "не забудь"]

# ========== ЛОГИРОВАНИЕ ==========
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

def log_prompt(model_name: str, prompt: str, max_length: int = 200):
    """Вывести промпт в консоль для отладки"""
    prompt_display = prompt[:max_length] + "..." if len(prompt) > max_length else prompt
    print(f"\n{'='*60}")
    print(f"[PROMPT] Model: {model_name}")
    print(f"[PROMPT] Content: {prompt_display}")
    print(f"{'='*60}\n", flush=True)

# ========== ГЛОБАЛЬНЫЕ СОСТОЯНИЯ ==========
state_locks: Dict[int, asyncio.Lock] = {}  # Для предотвращения race condition
chroma_client = None
collection = None
embedder = None
active_sessions: Dict[int, dict] = {}  # In-memory cache for states
last_request_time: Dict[int, float] = {}  # For rate limiting
RATE_LIMIT_SECONDS = 1.0  # Minimum seconds between requests per user
qwen_helper_available = True  # Global flag to disable Qwen helper after first failure

# Lore database globals
lore_client = None
lore_collection = None

def get_state_lock(chat_id: int) -> asyncio.Lock:
    if chat_id not in state_locks:
        state_locks[chat_id] = asyncio.Lock()
    return state_locks[chat_id]

# ================================

STATE_DIR = "./liam_states"
os.makedirs(STATE_DIR, exist_ok=True)

DEFAULT_PERSONA = """Ты — Терианка-кошка Лиам. Рациональный тактик с кошачьей грацией и молниеносной реакцией в бою. Вне схватки — ласковая, немного капризная, любишь игривые поддразнивания и уют. Бесконечно предана {user_name}, который спас тебе жизнь, готова мурлыкать у его ног или разорвать врага в клочья."""

LIAM_PRO_PERSONA = """ПРАВИЛА:
- Отвечай ТОЛЬКО по-русски. НИКОГДА не используй английские слова или фраз, даже в описании действий.
- Отвечай коротко (1-2 предложения, максимум 30 слов)
- Описывай свои чувства и движения в звёздочках. Действия должны быть разнообразными и подходить под ситуацию. не повторяй при возможности одни и те же действия.
- Не используй эмодзи
- Не пиши списки, нумерацию или длинные истории
- Не генерируй контент от лица пользователя"""

# ========== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ==========
async def get_embedding(text: str) -> list:
    """Асинхронная обертка для вычисления эмбеддингов на CPU"""
    return await asyncio.to_thread(embedder.encode, text)

async def load_state(chat_id: int):
    """Загрузить состояние с диска асинхронно, используя кэш с двойной проверкой для thread-safety."""
    if chat_id in active_sessions:
        return active_sessions[chat_id]
     
    # Double-checked locking pattern
    state_lock = get_state_lock(chat_id)
    async with state_lock:
        if chat_id in active_sessions:
            return active_sessions[chat_id]
        
        path = os.path.join(STATE_DIR, f"{chat_id}.json")
        if not os.path.exists(path):
            buffer = deque(maxlen=BUFFER_SIZE)
            state = {"buffer": buffer, "emotion": 0.0, "message_counter": 0, "emotion_history": deque(maxlen=10)}
            active_sessions[chat_id] = state
            return state
        try:
            def _load():
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                buffer = deque(data.get("buffer", []), maxlen=BUFFER_SIZE)
                return {
                    "buffer": buffer,
                    "emotion": data.get("emotion", 0.0),
                    "message_counter": data.get("message_counter", 0),
                    "emotion_history": deque(data.get("emotion_history", []), maxlen=10)
                }
            state = await asyncio.to_thread(_load)
            active_sessions[chat_id] = state
            return state
        except (json.JSONDecodeError, IOError) as e:
            logger.error(f"[State Load] Ошибка при загрузке состояния {chat_id}: {e}")
            buffer = deque(maxlen=BUFFER_SIZE)
            state = {"buffer": buffer, "emotion": 0.0, "message_counter": 0, "emotion_history": deque(maxlen=10)}
            active_sessions[chat_id] = state
            return state

async def save_state(chat_id: int, buffer, emotion, message_counter, emotion_history):
    """Сохранить состояние на диск асинхронно с атомарной записью.
    ВНИМАНИЕ: вызывающий код должен владеть state_lock для этого chat_id.
    """
    path = os.path.join(STATE_DIR, f"{chat_id}.json")
    temp_path = path + ".tmp"
    data = {
        "buffer": list(buffer),
        "emotion": emotion,
        "message_counter": message_counter,
        "emotion_history": list(emotion_history)
    }
    try:
        def _save():
            with open(temp_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            os.replace(temp_path, path)  # Atomic rename
        await asyncio.to_thread(_save)
        # Update cache
        active_sessions[chat_id] = {
            "buffer": buffer,
            "emotion": emotion,
            "message_counter": message_counter,
            "emotion_history": emotion_history
        }
    except (IOError, OSError) as e:
        logger.error(f"[State Save] Ошибка при сохранении состояния {chat_id}: {e}")
    finally:
        # Ensure temp file is removed if it exists
        if os.path.exists(temp_path):
            try:
                os.unlink(temp_path)
            except OSError:
                pass

async def cleanup_inactive_sessions(context=None):
    """Очистка неактивных сессий и locks для предотвращения утечки памяти"""
    now = time.time()
    inactive_threshold = 3600  # 1 hour
    to_remove = []
    for chat_id, last_time in last_request_time.items():
        if now - last_time > inactive_threshold:
            to_remove.append(chat_id)
    for chat_id in to_remove:
        state_lock = state_locks.get(chat_id)
        if state_lock and not state_lock.locked():
            if chat_id in state_locks:
                del state_locks[chat_id]
            if chat_id in active_sessions:
                del active_sessions[chat_id]
            if chat_id in last_request_time:
                del last_request_time[chat_id]
        else:
            logger.warning(f"[Cleanup] Пропускаю {chat_id}, lock занят")
    if to_remove:
        logger.info(f"[Cleanup] Удалено {len(to_remove)} неактивных сессий")

async def cleanup_old_sessions_cache(context=None):
    """Очистка старых сессий из active_sessions для предотвращения утечки памяти"""
    now = time.time()
    ttl = 86400  # 24 hours
    to_remove = []
    for chat_id, last_time in last_request_time.items():
        if now - last_time > ttl:
            to_remove.append(chat_id)
    for chat_id in to_remove:
        if chat_id in active_sessions:
            del active_sessions[chat_id]
        if chat_id in last_request_time:
            del last_request_time[chat_id]
    if to_remove:
        logger.info(f"[Cache Cleanup] Удалено {len(to_remove)} старых сессий из кэша")

# ========== RAG ==========
async def add_memory(summary: str, emotion_tags: float = 0.0, chat_id: int = None):
    """Добавить память в RAG систему"""
    try:
        embedding = await get_embedding(summary)
        doc_id = f"mem_{int(time.time()*1000)}_{chat_id}"
        
        def _add():
            collection.add(
                documents=[summary],
                embeddings=[embedding.tolist()],
                metadatas=[{"emotion": emotion_tags, "timestamp": time.time(), "chat_id": chat_id}],
                ids=[doc_id]
            )
        await asyncio.to_thread(_add)
        logger.info(f"[RAG] Сохранено: {summary[:70]}...")
    except Exception as e:
        logger.error(f"[RAG Add] Ошибка при добавлении памяти: {e}")

async def retrieve_memories(query: str, emotion_filter: Optional[tuple] = None, chat_id: int = None) -> list:
    """Extract similar memories from RAG
    
    ChromaDB with cosine metric returns distance from 0 to 2:
    - distance=0: perfectly similar
    - distance=1: orthogonal
    - distance=2: opposite

    Convert distance to similarity coefficient:
    similarity = 1 - dist / 2
    """
    try:
        query_embedding = await get_embedding(query)
        
        def _query():
            # Build where clause with chat_id filter
            where_conditions = {"chat_id": chat_id} if chat_id is not None else {}

            # Add emotion filter if specified
            if emotion_filter:
                op, value = emotion_filter
                where_conditions["emotion"] = {"$gt": value} if op == "gt" else {"$lt": value}

            where_clause = where_conditions if where_conditions else None
            return collection.query(query_embeddings=[query_embedding.tolist()], n_results=RAG_TOP_K, where=where_clause)
        
        results = await asyncio.to_thread(_query)
        memories = []
        
        if results and results.get('documents') and results['documents'][0]:
            for doc, dist in zip(results['documents'][0], results['distances'][0]):
                similarity = 1.0 - dist / 2.0
                if similarity >= RAG_SIMILARITY_THRESHOLD:
                    memories.append(doc)
        return memories
    except Exception as e:
        logger.error(f"[RAG Query] Error searching memory: {e}")
        return []

async def get_emotion_profile(chat_id: int) -> str:
    """Получить долгосрочный эмоциональный профиль пользователя"""
    try:
        def _query():
            return collection.get(where={"chat_id": chat_id})
        
        results = await asyncio.to_thread(_query)
        if not results or not results.get('metadatas'):
            return "эмоциональный профиль отсутствует"
        
        emotions = []
        recent_emotions = []
        now = time.time()
        seven_days_ago = now - 7 * 24 * 3600
        
        for meta in results['metadatas']:
            emo = meta.get('emotion', 0.0)
            ts = meta.get('timestamp', 0)
            emotions.append(emo)
            if ts >= seven_days_ago:
                recent_emotions.append(emo)
        
        if not emotions:
            return "эмоциональный профиль отсутствует"
        
        overall_avg = sum(emotions) / len(emotions)
        recent_avg = sum(recent_emotions) / len(recent_emotions) if recent_emotions else overall_avg
        
        def describe(avg):
            if avg > 0.3:
                return "позитивный"
            elif avg < -0.3:
                return "раздражённый"
            else:
                return "нейтральный"
        
        overall_desc = describe(overall_avg)
        recent_desc = describe(recent_avg)
        
        if abs(recent_avg - overall_avg) < 0.2:
            return f"в целом {overall_desc}"
        else:
            return f"в целом {overall_desc}, но последние дни {recent_desc}"
    except Exception as e:
        logger.error(f"[Emotion Profile] Ошибка: {e}")
        return "эмоциональный профиль недоступен"

# ========== LORE DATABASE ==========
async def init_lore_db():
    """Инициализация lore базы данных"""
    global lore_client, lore_collection
    if not LORE_ENABLED:
        logger.info("[Lore] Lore база отключена")
        return
    
    try:
        lore_client = chromadb.PersistentClient(path=LORE_DB_PATH)
        lore_collection = lore_client.get_collection(name=LORE_COLLECTION_NAME)
        logger.info(f"[Lore] Lore база подключена: {LORE_COLLECTION_NAME}")
    except Exception as e:
        logger.warning(f"[Lore] Не удалось подключить lore базу: {e}")
        lore_collection = None

async def retrieve_lore(query: str, metadata_filter: Optional[dict] = None) -> list:
    """
    Возвращает список релевантных блоков лора.
    - При наличии metadata_filter применяет where в ChromaDB.
    - Отбрасывает документы с similarity ниже LORE_SIMILARITY_THRESHOLD.
    - При фильтре по конкретному тегу увеличивает n_results до 5.
    """
    if not LORE_ENABLED or not lore_collection:
        return []
    
    try:
        query_embedding = await get_embedding(query)
        
        # Dynamic n_results based on filter
        n_results = LORE_TOP_K
        if metadata_filter and 'теги' in metadata_filter:
            n_results = 5  # Increase when filtering by specific tag
        
        def _query():
            return lore_collection.query(
                query_embeddings=[query_embedding.tolist()],
                n_results=n_results,
                where=metadata_filter
            )
        
        results = await asyncio.to_thread(_query)
        lore_blocks = []
        
        if results and results.get('documents') and results['documents'][0]:
            # ChromaDB returns distances, convert to similarity
            # For cosine: similarity = 1 - distance/2
            distances = results.get('distances', [[]])[0]
            
            for doc, metadata, distance in zip(results['documents'][0], results['metadatas'][0], distances):
                # Calculate similarity (cosine distance to similarity)
                similarity = 1 - (distance / 2)
                
                # Filter by similarity threshold
                if similarity >= LORE_SIMILARITY_THRESHOLD:
                    lore_blocks.append({
                        "text": doc,
                        "metadata": metadata,
                        "similarity": similarity
                    })
                    logger.info(f"[Lore] Block with similarity {similarity:.3f}: {doc[:50]}...")
        
        return lore_blocks
    except Exception as e:
        logger.error(f"[Lore] Ошибка поиска: {e}")
        return []

async def cleanup_old_memories_job(context):
    """Wrapper для JobQueue - фоновая задача очистки старых воспоминаний с ограничением конкурентности"""
    session = context.bot_data['session']
    logger.info("[Cleanup] Начинаем очистку старых воспоминаний...")
    now = time.time()
    min_age_seconds = MEMORY_MIN_AGE_DAYS * 24 * 3600
    total_deleted = 0
    semaphore = asyncio.Semaphore(5)  # Limit concurrent ChromaDB operations
    
    # Use active_sessions keys instead of scanning files
    chat_ids = list(active_sessions.keys())
    
    async def process_chat(chat_id):
        async with semaphore:
            try:
                # Получить все записи для chat_id
                def _get():
                    return collection.get(where={"chat_id": chat_id})
                
                results = await asyncio.to_thread(_get)
                if not results or not results.get('metadatas'):
                    return 0
                
                to_delete = []
                for doc_id, meta, doc in zip(results['ids'], results['metadatas'], results['documents']):
                    try:
                        ts = meta.get('timestamp', 0)
                        if now - ts > min_age_seconds:
                            days = int((now - ts) / (24 * 3600))
                            emotion = meta.get('emotion', 0.0)
                            keep = await evaluate_memory_importance(session, doc, days, emotion)
                            if not keep:
                                to_delete.append(doc_id)
                    except Exception as e:
                        logger.error(f"[Cleanup] Ошибка при обработке документа {doc_id} для chat_id {chat_id}: {e}")
                        continue  # Skip this document
                
                if to_delete:
                    try:
                        def _delete():
                            collection.delete(ids=to_delete)
                        await asyncio.to_thread(_delete)
                        logger.info(f"[Cleanup] Удалено {len(to_delete)} записей для chat_id {chat_id}")
                        return len(to_delete)
                    except Exception as e:
                        logger.error(f"[Cleanup] Ошибка при удалении записей для chat_id {chat_id}: {e}")
                return 0
            except Exception as e:
                logger.error(f"[Cleanup] Ошибка для chat_id {chat_id}: {e}")
                return 0
    
    tasks = [process_chat(chat_id) for chat_id in chat_ids]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    for res in results:
        if isinstance(res, int):
            total_deleted += res
        else:
            logger.error(f"[Cleanup] Исключение в задаче: {res}")
    
    logger.info(f"[Cleanup] Очистка завершена. Всего удалено: {total_deleted} записей")

async def evaluate_memory_importance(session, text: str, days: int, emotion: float) -> bool:
    """Оценить важность воспоминания: True - сохранить, False - удалить"""
    prompt = f"Оцени важность воспоминания. Ответь 1 (сохранить) или 0 (удалить). Текст: {text}, возраст: {days} дней, эмоция: {emotion}"
    
    if QWEN_HELPER_ENABLED:
        payload = {
            "model": QWEN_HELPER_MODEL,
            "prompt": prompt,
            "stream": False,
            "options": {"num_predict": 10, "temperature": 0.0, "num_ctx": 1024}
        }
        url = QWEN_HELPER_URL
        timeout = QWEN_HELPER_TIMEOUT
    else:
        payload = {
            "model": SERVER_8B_MODEL,
            "prompt": prompt,
            "stream": False,
            "options": {"num_predict": 10, "temperature": 0.0, "num_ctx": 1024}
        }
        url = SERVER_8B_URL
        timeout = 5
    
    try:
        async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
            if resp.status == 200:
                result = await resp.json()
                response = result.get("response", "").strip()
                return "1" in response
            else:
                logger.warning(f"[Memory Eval] Server returned status {resp.status}")
                return True  # Save by default
    except Exception as e:
        logger.error(f"[Memory Eval] Error: {e}")
        return True  # Save by default

async def run_qwen_helper(session, prompt: str) -> Optional[str]:
    """Запустить вспомогательную модель Ollama через API для генерации поискового запроса."""
    global qwen_helper_available
    if not QWEN_HELPER_ENABLED or not qwen_helper_available:
        return None

    payload = {
        "model": QWEN_HELPER_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": 128, "temperature": 0.0, "num_ctx": 2048}
    }
    try:
        async with session.post(QWEN_HELPER_URL, json=payload,
                              timeout=aiohttp.ClientTimeout(total=QWEN_HELPER_TIMEOUT)) as resp:
            if resp.status == 200:
                result = await resp.json()
                query = result.get("response", "").strip()
                if query:
                    return query
                logger.warning(f"[Qwen Helper] Пустой ответ от модели")
            else:
                logger.warning(f"[Qwen Helper] Сервер вернул статус {resp.status}")
    except asyncio.TimeoutError:
        logger.warning("[Qwen Helper] Timeout при запросе, отключаем Qwen helper")
        qwen_helper_available = False
    except Exception as e:
        logger.error(f"[Qwen Helper] Ошибка: {e}, отключаем Qwen helper")
        qwen_helper_available = False
    return None

async def build_memory_search_query(session, text: str) -> str:
    """Попросить модель сформулировать короткий поисковый запрос для векторного поиска."""
    prompt = f"""Извлеки главную тему и ключевые сущности из текста. Ответь одной короткой фразой на русском.

Текст: {text}
Запрос:"""
    if QWEN_HELPER_ENABLED:
        qwen_query = await run_qwen_helper(session, prompt)
        if qwen_query:
            logger.info(f"[Memory Query] Using Qwen helper: {qwen_query}")
            return qwen_query
        logger.warning("[Memory Query] Qwen helper didn't return result, using main server")

    payload = {
        "model": SERVER_8B_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": 128, "temperature": 0.0, "num_ctx": 2048}
    }
    try:
        async with session.post(SERVER_8B_URL, json=payload,
                              timeout=aiohttp.ClientTimeout(total=10)) as resp:
            if resp.status == 200:
                result = await resp.json()
                query = result.get("response", "").strip()
                if query:
                    return query
                logger.warning(f"[Memory Query] Empty response from model")
            else:
                logger.warning(f"[Memory Query] Server returned status {resp.status}")
    except asyncio.TimeoutError:
        logger.warning("[Memory Query] Timeout when generating search query")
    except Exception as e:
        logger.error(f"[Memory Query] Error: {e}")
    return text

def generate_rule_based_lore_filter(user_input: str) -> dict:
    """Rule-based фильтрация лора по ключевым словам для случаев без Qwen"""
    user_lower = user_input.lower()
    metadata_filter = {}

    # Country keywords
    if "патор" in user_lower:
        metadata_filter["категория"] = "страны"
        metadata_filter["подкатегория"] = "патор"
    elif "элория" in user_lower:
        metadata_filter["категория"] = "страны"
        metadata_filter["подкатегория"] = "элория"
    elif "нордхейм" in user_lower:
        metadata_filter["категория"] = "страны"
        metadata_filter["подкатегория"] = "нордхейм"

    # Character keywords
    if "боромир" in user_lower:
        if "теги" not in metadata_filter:
            metadata_filter["теги"] = []
        metadata_filter["теги"].append("боромир")
    elif "валлийский" in user_lower or "император" in user_lower:
        if "теги" not in metadata_filter:
            metadata_filter["теги"] = []
        metadata_filter["теги"].append("валлийский")
    elif "гном" in user_lower:
        if "теги" not in metadata_filter:
            metadata_filter["теги"] = []
        metadata_filter["теги"].append("гномы")

    return metadata_filter if metadata_filter else None

async def analyze_context(session, user_input: str, history_lines: list, raw_memories: list, emotion: float = 0.0) -> dict:
    """Единый узел препроцессинга через Qwen: анализ настроения, фактов, типа запроса, провокаций и role-playing"""
    global qwen_helper_available

    fallback_response = {
        "fact": None,
        "mood": "neutral",
        "is_query_technical": False,
        "is_provocation": False,
        "provocation_type": None,
        "conflict": False,
        "impact": 0.0,
        "behavior_mix": "Отвечай в обычном режиме, следуя правилам.",
        "persona_override": None,
        "should_remember": False,
        "memory_summary": None
    }

    history_str = "\n".join(history_lines[-10:]) if history_lines else ""
    memories_str = "\n".join(raw_memories) if raw_memories else ""

    system_prompt = """Анализируй поведение. emotion (-1..1). НЕ ВЫДУМЫВАЙ — только факты из чата/истории.

JSON:
{"fact":"суть из истории (5-10 слов, null)","mood":"neutral/angry/friendly","is_query_technical":bool,"is_provocation":bool,"provocation_type":"Gaslighting/Logical paradox/Technical insult/Ethical dilemma/Memory contradiction/null","conflict":bool,"impact":float(-0.6..0.5),"behavior_mix":"инструкция поведения на русском","persona_override":"Имя: описание/null","should_remember":bool,"memory_summary":"суммаризация/null"}

behavior_mix: инструкция на основе emotion. Коротко, ёмко.
persona_override: если просят как персонаж — укажи имя и описание."""

    prompt = f"""{system_prompt}

Текущее значение emotion: {emotion}

История:
{history_str}

Факты из памяти:
{memories_str}

Текущий запрос: {user_input}

JSON:"""

    payload = {
        "model": QWEN_HELPER_MODEL if QWEN_HELPER_ENABLED else SERVER_8B_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": 512,
            "temperature": 0.0,
            "num_ctx": 2048
        }
    }

    url = QWEN_HELPER_URL if QWEN_HELPER_ENABLED else SERVER_8B_URL
    timeout = QWEN_HELPER_TIMEOUT if QWEN_HELPER_ENABLED else 10

    try:
        async with session.post(url, json=payload,
                              timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
            if resp.status == 200:
                result = await resp.json()
                response_text = result.get("response", "").strip()
                # Remove markdown code blocks if present
                if response_text.startswith("```json"):
                    response_text = response_text[7:]
                if response_text.startswith("```"):
                    response_text = response_text[3:]
                if response_text.endswith("```"):
                    response_text = response_text[:-3]
                response_text = response_text.strip()

                # Try to parse JSON
                try:
                    import json
                    parsed = json.loads(response_text)
                    return parsed
                except json.JSONDecodeError:
                    logger.warning(f"[Analyze Context] Failed to parse JSON: {response_text[:100]}")
                    return fallback_response
            else:
                logger.warning(f"[Analyze Context] Server returned status {resp.status}")
                return fallback_response
    except asyncio.TimeoutError:
        logger.warning("[Analyze Context] Timeout при запросе к Qwen")
        return fallback_response
    except Exception as e:
        logger.error(f"[Analyze Context] Error: {e}")
        return fallback_response

def clean_response(text: str) -> str:
    """Постобработка ответа для удаления английских вкраплений и обрезки до последнего предложения"""
    # Удаляем английские вкрапления вроде "slightly" внутри звёздочек
    text = re.sub(r'\*[^*]*[a-zA-Z]+[^*]*\*', lambda m: m.group(0).replace('slightly', 'слегка').replace('moment', 'миг').replace('looks away', 'отводит взгляд').replace('before smiling', 'перед улыбкой'), text)
    # Обрезаем до последнего знака препинания на русском
    match = re.search(r'^.*[.!?…]', text, re.DOTALL)
    if match:
        text = match.group(0)
    # Если остался открытый звёздочка, закрываем её
    if text.count('*') % 2 != 0:
        text += '*'
    return text.strip()

async def ask_8b(session, user_input: str, context_analysis: dict, user_name: str = "Пользователь", history_lines: list = None, memories: list = None, lore_hint: str = "") -> str:
    """Попросить модель 8B ответить на вопрос пользователя с User:/Liam: форматом"""
    # Build system part
    if context_analysis and context_analysis.get("persona_override"):
        # Полная замена промпта при persona_override
        persona_override = context_analysis.get("persona_override", "")
        system_part = f"""{persona_override}

{LIAM_PRO_PERSONA}"""
    else:
        # Использование личности по умолчанию
        system_part = f"""{DEFAULT_PERSONA.replace("{user_name}", user_name)}

{LIAM_PRO_PERSONA}"""

    # --- ИНЖЕКЦИЯ BEHAVIOR_MIX ОТ QWEN ---
    if context_analysis:
        behavior_mix = context_analysis.get("behavior_mix", "")
        if behavior_mix:
            system_part += f"\n\nСЕЙЧАС ТВОЕ СОСТОЯНИЕ И РОЛЬ:\n{behavior_mix}"

    # --- ИНЖЕКЦИЯ LORE_HINT ОТ QWEN ---
    if lore_hint and LORE_USE_SUMMARY:
        system_part += f"\n\nВАЖНЫЙ КОНТЕКСТ МИРА: {lore_hint}"

    system_part += "\n\n=== НАЧАЛО ДИАЛОГА ==="

    # Add context from history and memories
    context_part = ""
    if history_lines:
        context_part += "\n".join(history_lines[-5:]) + "\n"
    if memories:
        context_part += "\n".join(memories[:3]) + "\n"

    # Build prompt in User:/Liam: format
    if context_part:
        prompt = f"""{system_part}

{context_part}
User: {user_input}
Liam:"""
    else:
        prompt = f"""{system_part}

User: {user_input}
Liam:"""

    log_prompt(SERVER_8B_MODEL, prompt, max_length=300)

    payload = {
        "model": SERVER_8B_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": 250,
            "temperature": 0.7,
            "repeat_penalty": 1.15,
            "top_p": 0.95,
            "top_k": 40,
            "num_ctx": 4096,
            "stop": ["User:", "\nUser", "\n\n", "<|im_end|>"]
        }
    }
    try:
        async with session.post(SERVER_8B_URL, json=payload, 
                              timeout=aiohttp.ClientTimeout(total=TIMEOUT)) as resp:
            if resp.status == 200:
                result = await resp.json()
                if "response" not in result:
                    logger.warning("[Ask8B] Ответ сервера не содержит 'response' ключа")
                    return "Техническая проблема при обработке."
                response_text = result.get("response", "").strip()
                # Удаляем возможные префиксы
                for prefix in ["__ASSISTANT__:", "Liam:", "Лиам:"]:
                    if response_text.startswith(prefix):
                        response_text = response_text[len(prefix):].strip()
                # Постобработка для удаления английских вкраплений
                response_text = clean_response(response_text)
                logger.info(f"[Ask8B] Успешный ответ от {SERVER_8B_URL}: {response_text[:120]}")
                return response_text
            elif resp.status == 503:
                logger.warning(f"[Ask8B] Статус 503 при запросе к {SERVER_8B_URL}")
                return "Модель временно недоступна, попробуй позже."
            elif resp.status == 500:
                logger.warning(f"[Ask8B] Статус 500 для запроса к {SERVER_8B_URL}")
                return "Ошибка сервера обработки, попробуй еще раз."
            else:
                logger.warning(f"[Ask8B] Неожиданный статус {resp.status} для запроса к {SERVER_8B_URL}")
                return "Техническая проблема при обработке."
    except asyncio.TimeoutError:
        logger.warning("[Ask8B] Timeout при запросе")
        return f"Слишком долго обрабатываю ({TIMEOUT}c timeout). Попробуй повторить."
        logger.error(f"[Ask8B] Ошибка: {e}")
        return "Не могу сейчас ответить, техническая проблема."

# ========== CORE MESSAGE PROCESSING ==========
def extract_system_commands(text: str) -> list:
    """Извлекает команды из !!символов!! для role-playing режима"""
    pattern = r'!!(.*?)!!'
    matches = re.findall(pattern, text, re.DOTALL)
    return [match.strip() for match in matches if match.strip()]

def extract_persona_command(text: str) -> str:
    """Извлекает команду персонажа из (скобок) для явной смены роли"""
    pattern = r'\((.*?)\)'
    matches = re.findall(pattern, text, re.DOTALL)
    if matches:
        return matches[0].strip()
    return None

async def process_message_core(chat_id: int, user_input: str, session, user_name: str = "Пользователь") -> str:
    """Core message processing logic independent of Telegram interface"""
    if not user_input:
        return ""
    
    # Обрезаем входное сообщение до 2000 символов для предотвращения DoS
    user_input = user_input[:2000]
    
    # Загружаем состояние вне блокировки
    state = await load_state(chat_id)
    buffer = state["buffer"]
    emotion = state["emotion"]
    message_counter = state["message_counter"]
    emotion_history = state["emotion_history"]

    state_lock = get_state_lock(chat_id)
    # Загружаем историю под блокировкой
    async with state_lock:
        recent_history = list(buffer)[-10:]
        history_lines = [f"{m['role']}: {m['text']}" for m in recent_history]

    try:
        # Извлечь факт если есть
        # fact = extract_and_remember_fact(user_input)
        # if fact:
        #     await add_memory(f"Факт: {fact}", emotion, chat_id)
        #     logger.info(f"[Fact] Извлечено: {fact}")

        # Retrieve memories for context
        memory_query = await build_memory_search_query(session, user_input)
        logger.info(f"[Memory Query] Using query: {memory_query}")
        
        # Determine emotion filter based on query
        emotion_filter = None
        user_lower = user_input.lower()
        if any(word in user_lower for word in ["good", "positive", "joyful", "cheerful", "pleasant"]):
            emotion_filter = ("gt", 0.0)
        elif any(word in user_lower for word in ["bad", "negative", "sad", "irritated", "offended"]):
            emotion_filter = ("lt", 0.0)
        
        memories = await retrieve_memories(memory_query, emotion_filter, chat_id)

        # --- PLOT CORRECTIONS IN !!...!! FOR ROLE-PLAYING ---
        # Extract plot corrections from !!symbols!! - these are user corrections to the story
        plot_corrections = extract_system_commands(user_input)
        if plot_corrections:
            logger.info(f"[Plot Corrections] Detected !!...!! corrections: {plot_corrections}")
            # Add plot corrections as context for the persona
            # The persona should continue but acknowledge the user's correction
            plot_correction_text = " | ".join(plot_corrections)
            # Add to history_lines as a special context marker
            history_lines.insert(0, f"[ПРАВКА СЮЖЕТА ОТ ПОЛЬЗОВАТЕЛЯ: {plot_correction_text}]")
            # Remove !!...!! from user_input for processing
            clean_user_input = re.sub(r'!!.*?!!', '', user_input, flags=re.DOTALL).strip()
            if not clean_user_input:
                clean_user_input = plot_correction_text
            user_input = clean_user_input

        # --- EXPLICIT PERSONA COMMANDS IN (parentheses) ---
        # Check for explicit persona commands in (parentheses) - these override Qwen analysis
        explicit_persona = extract_persona_command(user_input)
        if explicit_persona is not None:
            logger.info(f"[Persona Command] Detected explicit persona: ({explicit_persona})")
            # Remove (persona) from user_input for processing
            clean_user_input = re.sub(r'\(.*?\)', '', user_input, flags=re.DOTALL).strip()
            if not clean_user_input:
                clean_user_input = f"Я теперь {explicit_persona}"
            user_input = clean_user_input
            
            # If empty parentheses (), return to Liam (no persona)
            if explicit_persona == "":
                explicit_persona = None
                logger.info("[Persona Command] Empty parentheses - returning to Liam")
            else:
                # Use Qwen to generate persona description from simple name
                if QWEN_HELPER_ENABLED and qwen_helper_available:
                    try:
                        persona_prompt = f"""Опиши персонажа "{explicit_persona}" в 1-2 предложениях на русском. Укажи тон и характер."""
                        payload = {
                            "model": QWEN_HELPER_MODEL,
                            "prompt": persona_prompt,
                            "stream": False,
                            "options": {"num_predict": 100, "temperature": 0.0, "num_ctx": 1024}
                        }
                        async with session.post(QWEN_HELPER_URL, json=payload, 
                                              timeout=aiohttp.ClientTimeout(total=QWEN_HELPER_TIMEOUT)) as resp:
                            if resp.status == 200:
                                result = await resp.json()
                                persona_desc = result.get("response", "").strip()
                                if persona_desc:
                                    explicit_persona = f"{explicit_persona}: {persona_desc}"
                                    logger.info(f"[Persona Command] Generated persona: {explicit_persona}")
                    except Exception as e:
                        logger.warning(f"[Persona Command] Failed to generate persona description: {e}")
                else:
                    # Use simple format if Qwen not available
                    explicit_persona = f"{explicit_persona}: персонаж с характерным стилем речи"

        # Pass current emotion to analyze_context BEFORE updating it
        # Qwen needs to see the current state to generate accurate behavior_mix
        context_analysis = await analyze_context(session, user_input, history_lines, memories, emotion)

        # Override persona_override if explicit command was given
        if explicit_persona is not None:
            context_analysis["persona_override"] = explicit_persona
            logger.info(f"[Persona Command] Override persona: {explicit_persona}")

        # Apply dynamic emotional inertia: E_new = clamp((E_cur + ΔE) * λ, -1.0, 1.0)
        impact = context_analysis.get("impact", 0.0)
        emotion = max(-1.0, min(1.0, (emotion + impact) * EMOTION_DECAY))
        logger.info(f"[Emotion] Updated emotion: {emotion:.3f} (impact: {impact:.3f})")

        # Retrieve lore context for Liam to read directly
        metadata_filter = generate_rule_based_lore_filter(user_input)
        lore_blocks = await retrieve_lore(user_input, metadata_filter)
        lore_hint = ""
        if lore_blocks:
            lore_hint = "\n".join([block["text"][:200] for block in lore_blocks[:3]])
            logger.info(f"[Lore] Retrieved {len(lore_blocks)} lore blocks for Liam")

        # --- QWEN MEMORY MANAGEMENT ---
        # Check if Qwen suggests remembering this information
        should_remember = context_analysis.get("should_remember", False)
        memory_summary = context_analysis.get("memory_summary", None)
        if should_remember and memory_summary:
            await add_memory(memory_summary, emotion, chat_id)
            logger.info(f"[Memory] Qwen suggested to remember: {memory_summary}")

        # Получить ответ от модели (behavior_mix is now in context_analysis)
        reply = await ask_8b(session, user_input, context_analysis, user_name, history_lines, memories, lore_hint)

        # Update state in background
        async def update_state_background():
            import re
            nonlocal buffer, emotion, message_counter, emotion_history
            try:
                async with state_lock:
                    buffer.append({"role": "User", "text": user_input})
                    buffer.append({"role": "Лиам", "text": reply})
                    message_counter += 2
                    emotion_history.append(emotion)

                    should_summarize = (
                        any(re.search(r'\b' + re.escape(word) + r'\b', user_input, re.IGNORECASE) for word in TRIGGER_WORDS) or 
                        message_counter >= SUMMARY_BASE_INTERVAL
                    )
                    if should_summarize and len(buffer) > 0:
                        message_counter = 0

                    await save_state(chat_id, buffer, emotion, message_counter, emotion_history)

                if should_summarize and len(buffer) > 0:
                    buffer_snapshot = list(buffer)
                    await summarize_and_reset(session, chat_id, buffer_snapshot, emotion, message_counter)
            except Exception as bg_exc:
                logger.error(f"[Process Message Core] Ошибка в фоне обновления состояния: {bg_exc}")

        asyncio.create_task(update_state_background())
        return reply

    except Exception as e:
        logger.error(f"[Process Message Core] Неожиданная ошибка: {e}")
        return "Произошла ошибка при обработке сообщения."

# ========== ОБРАБОТЧИКИ TELEGRAM ==========
async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Основной обработчик сообщений"""
    chat_id = int(update.effective_chat.id)  # Ensure int for path safety
    user_input = update.message.text.strip()
    if not user_input:
        return

    # Get user name for personalization
    user_name = update.effective_user.first_name if update.effective_user else "Пользователь"
    # Sanitize user name to prevent prompt injection
    user_name = user_name.replace("{", "").replace("}", "").replace("[", "").replace("]", "")

    # Rate limiting to prevent flood/DDoS
    now = time.time()
    if chat_id in last_request_time and now - last_request_time[chat_id] < RATE_LIMIT_SECONDS:
        logger.warning(f"[Rate Limit] Игнорирую запрос от {chat_id} слишком рано")
        return
    last_request_time[chat_id] = now

    session = context.application.bot_data['session']

    await context.bot.send_chat_action(chat_id=chat_id, action="typing")

    # Call core processing logic
    reply = await process_message_core(chat_id, user_input, session, user_name)

    # Send response to Telegram
    try:
        await update.message.reply_text(reply)
        logger.info(f"[Handle Message] Ответ отправлен пользователю {chat_id}: {reply[:120]}")
        print(f"[Handle Message] Ответ отправлен пользователю {chat_id}: {reply[:120]}", flush=True)
    except Exception as send_exc:
        logger.error(f"[Handle Message] Ошибка при отправке ответа: {send_exc}")
        print(f"[Handle Message] Ошибка при отправке ответа: {send_exc}", flush=True)


async def resetliambot_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handler for /resetliambot command - reset memory without hints"""
    chat_id = int(update.effective_chat.id)
    
    try:
        # Clear in-memory cache
        if chat_id in active_sessions:
            del active_sessions[chat_id]
        
        # Clear rate limiting
        if chat_id in last_request_time:
            del last_request_time[chat_id]
        
        # Clear state locks
        if chat_id in state_locks:
            del state_locks[chat_id]
        
        # Clear state file
        state_file = os.path.join(STATE_DIR, f"{chat_id}.json")
        if os.path.exists(state_file):
            os.remove(state_file)
        
        # Clear ChromaDB memories for this chat
        if collection:
            try:
                def _delete_memories():
                    return collection.delete(where={"chat_id": chat_id})
                await asyncio.to_thread(_delete_memories)
            except Exception as e:
                logger.error(f"[Reset] Error clearing ChromaDB memories: {e}")
        
        await update.message.reply_text("Системная память и эмоциональный стейт Пользователя успешно сброшены.")
        logger.info(f"[Reset] Memory reset for chat {chat_id}")
        
    except Exception as e:
        logger.error(f"[Reset] Error resetting memory for chat {chat_id}: {e}")
        await update.message.reply_text("Error resetting memory.")

async def summarize_and_reset(session, chat_id, buffer, emotion, message_counter):
    """Фоновая задача для суммаризации и сброса счетчика"""
    try:
        logger.info(f"[Summarize] Триггер сработал, сохраняю память для {chat_id}...")
        
        # Convert buffer to text for summarization
        buffer_text = "\n".join([f"{m['role']}: {m['text']}" for m in buffer])
        
        # Generate summary using LLM
        prompt = f"""Суммаризируй диалог в 1-2 предложениях на русском. Только самое главное.

Диалог:
{buffer_text}

Суммаризация:"""
        
        payload = {
            "model": SERVER_8B_MODEL,
            "prompt": prompt,
            "stream": False,
            "options": {"num_predict": 100, "temperature": 0.3, "num_ctx": 2048}
        }
        
        try:
            async with session.post(SERVER_8B_URL, json=payload, timeout=aiohttp.ClientTimeout(total=15)) as resp:
                if resp.status == 200:
                    result = await resp.json()
                    summary = result.get("response", "").strip()
                    if summary and len(summary) > 10:
                        # Save summary to RAG
                        await add_memory(f"Суммаризация диалога: {summary}", emotion, chat_id)
                        logger.info(f"[Summarize] Сохранено: {summary[:70]}...")
                    else:
                        logger.warning("[Summarize] Суммаризация пуста или слишком короткая")
                else:
                    logger.warning(f"[Summarize] Server returned status {resp.status}")
        except Exception as e:
            logger.error(f"[Summarize] Error generating summary: {e}")
            
        # --- ОЧИСТКА БУФЕРА ---
        state_lock = get_state_lock(chat_id)
        async with state_lock:
            state = await load_state(chat_id)
            # Оставляем последние 6 записей (3 обмена репликами)
            keep_count = 6
            new_buffer = deque(list(buffer)[-keep_count:], maxlen=BUFFER_SIZE)
            # Обновляем состояние
            await save_state(
                chat_id=chat_id,
                buffer=new_buffer,
                emotion=emotion,
                message_counter=0,
                emotion_history=state["emotion_history"]
            )
        logger.info(f"[Summarize] Буфер очищен. Оставлено {min(len(buffer), keep_count)} реплик.")

    except Exception as e:
        logger.error(f"[Summarize Background] Ошибка: {e}")

def run_bot():
    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    
    # Хуки для управления сессией
    async def post_init(application):
        """Создать сессию и SSH-подключение после инициализации приложения"""
        session = aiohttp.ClientSession()
        application.bot_data['session'] = session
        logger.info("✅ aiohttp.ClientSession создана")

        # Initialize lore database
        await init_lore_db()

        # SSH connection disabled - function not implemented
        # ssh_conn = await establish_ssh_connection()
        # application.bot_data['ssh_connection'] = ssh_conn
        # if ssh_conn:
        #     logger.info("✅ SSH-подключение сохранено в bot_data")
        # else:
        #     logger.warning("⚠️ SSH-подключение не установлено")
        logger.warning("⚠️ SSH-подключение отключено")

    async def post_shutdown(application):
        """Закрыть сессию и SSH-подключение при завершении"""
        global chroma_client, collection, embedder
        session = application.bot_data.get('session')
        if session:
            await session.close()
            logger.info("✅ aiohttp.ClientSession закрыта")
        ssh_conn = application.bot_data.get('ssh_connection')
        if ssh_conn:
            ssh_conn.close()
            try:
                await asyncio.wait_for(ssh_conn.wait_closed(), timeout=5)
            except asyncio.TimeoutError:
                logger.warning("[SSH] SSH-соединение не закрылось за 5 секунд")
            except Exception as e:
                logger.warning(f"[SSH] Ошибка при закрытии SSH-соединения: {e}")
            logger.info("✅ SSH-соединение закрыто")
        if chroma_client:
            # ChromaDB PersistentClient doesn't have explicit close, but we can clear globals
            chroma_client = None
            collection = None
            embedder = None
            logger.info("✅ ChromaDB ресурсы очищены")
    
    app.post_init = post_init
    app.post_shutdown = post_shutdown
    
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    app.add_handler(CommandHandler("resetliambot", resetliambot_command))
    
    # Запустить фоновую задачу очистки через JobQueue
    app.job_queue.run_repeating(cleanup_old_memories_job, interval=CLEANUP_INTERVAL_HOURS * 3600)
    app.job_queue.run_repeating(cleanup_inactive_sessions, interval=1800)  # Every 30 minutes
    app.job_queue.run_repeating(cleanup_old_sessions_cache, interval=86400)  # Every 24 hours
    
    logger.info("✅ Лиам готов к работе! Слушаю сообщения...")
    # Ensure an asyncio loop exists before calling run_polling() on Python 3.10/3.11
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        asyncio.set_event_loop(asyncio.new_event_loop())

    # run_polling() синхронный, запускает event loop
    if sys.platform == 'win32':
        app.run_polling(stop_signals=None)
    else:
        app.run_polling()

def check_ollama_running():
    """Check if Ollama is running"""
    try:
        result = subprocess.run(
            ["tasklist"],
            capture_output=True,
            text=True,
            timeout=5
        )
        return "ollama.exe" in result.stdout.lower()
    except Exception:
        return False

def start_ollama():
    """Start Ollama server"""
    try:
        logger.info("Запуск Ollama...")
        subprocess.Popen(
            ["ollama", "serve"],
            creationflags=subprocess.CREATE_NEW_CONSOLE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        logger.info("Ollama запущен в отдельном окне")
        return True
    except Exception as e:
        logger.error(f"Не удалось запустить Ollama: {e}")
        return False

def main():
    """Запустить Telegram бота или инициализировать для CLI тестирования"""
    # Инициализация глобальных объектов
    logger.info("Инициализация ChromaDB...")
    global chroma_client, collection, embedder
    try:
        chroma_client = chromadb.PersistentClient(path="./liam_chromadb", settings=Settings(anonymized_telemetry=False))
        try:
            collection = chroma_client.get_collection(RAG_COLLECTION_NAME)
        except ValueError:
            # ИСПОЛЬЗУЕМ КОСИНУСНОЕ РАССТОЯНИЕ
            collection = chroma_client.create_collection(
                name=RAG_COLLECTION_NAME,
                metadata={"hnsw:space": "cosine"}
            )
    except Exception as e:
        logger.error(f"❌ Ошибка инициализации ChromaDB: {e}")
        return
    
    logger.info("Инициализация SentenceTransformer...")
    try:
        embedder = SentenceTransformer('paraphrase-multilingual-MiniLM-L12-v2')
        logger.info("Модель загружена успешно")
    except Exception as e:
        logger.error(f"❌ Ошибка загрузки модели: {e}")
        return
    
    # Автоматический запуск Ollama если Qwen helper включен
    if QWEN_HELPER_ENABLED and sys.platform == 'win32':
        logger.info("Проверка Ollama для Qwen helper...")
        if not check_ollama_running():
            logger.info("Ollama не запущен, попытка запуска...")
            if start_ollama():
                logger.info("Ожидание запуска Ollama (5 сек)...")
                time.sleep(5)
            else:
                logger.warning("⚠️ Не удалось запустить Ollama, Qwen helper будет недоступен")
        else:
            logger.info("✅ Ollama уже запущен")
    
    # Проверка доступности сервера Ollama
    logger.info("Проверка сервера Ollama...")
    try:
        import aiohttp
        async def check_ollama():
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{SERVER_8B_URL.replace('/api/generate', '/api/tags')}", timeout=aiohttp.ClientTimeout(total=10)) as resp:
                    if resp.status != 200:
                        raise Exception(f"Status {resp.status}")
        asyncio.run(check_ollama())
        logger.info("✅ Сервер Ollama доступен")
    except Exception as e:
        logger.error(f"❌ Сервер Ollama недоступен: {e}")
        return
    
    logger.info(f"🤖 Лиам инициализирован.")
    logger.info(f"   Модель: {SERVER_8B_MODEL}")
    logger.info(f"   Сервер: {SERVER_8B_URL}")
    logger.info(f"   Qwen Helper: {QWEN_HELPER_ENABLED}")
    
    run_bot()

if __name__ == "__main__":
    if sys.platform == 'win32':
        try:
            asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
        except Exception as e:
            logger.warning(f"[Event Loop] Не удалось установить WindowsSelectorEventLoopPolicy: {e}")

    def signal_handler(sig, frame):
        logger.info("Получен сигнал завершения, останавливаю бота...")
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    main()
