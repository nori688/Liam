#!/usr/bin/env python3
"""
Скрипт для индексации базы знаний из JSON-текстовика в ChromaDB
"""

import json
import os
from typing import List, Dict, Any
from sentence_transformers import SentenceTransformer
import chromadb
from chromadb.config import Settings


def load_lore_data(filepath: str) -> List[Dict[str, Any]]:
    """Загружает JSON данные из файла"""
    with open(filepath, 'r', encoding='utf-8') as f:
        data = json.load(f)
    return data


def flatten_metadata(metadata: Dict[str, Any]) -> Dict[str, Any]:
    """Преобразует вложенные списки в метаданных в строки через запятую"""
    flattened = {}
    for key, value in metadata.items():
        if isinstance(value, list):
            flattened[key] = ", ".join(str(item) for item in value)
        else:
            flattened[key] = str(value)
    return flattened


def split_text_if_needed(text: str, chunk_size: int = 800, chunk_overlap: int = 100) -> List[str]:
    """Разбивает длинный текст на чанки если нужно"""
    if len(text) <= 1000:
        return [text]
    
    # Простое разбиение по предложениям для экономии памяти
    # (без LangChain для уменьшения зависимостей)
    chunks = []
    sentences = text.split('. ')
    current_chunk = ""
    
    for sentence in sentences:
        if len(current_chunk) + len(sentence) + 2 <= chunk_size:
            current_chunk += sentence + ". "
        else:
            if current_chunk:
                chunks.append(current_chunk.strip())
            current_chunk = sentence + ". "
    
    if current_chunk:
        chunks.append(current_chunk.strip())
    
    return chunks if chunks else [text]


def ingest_lore_to_chroma(
    lore_data: List[Dict[str, Any]],
    chroma_path: str = "./chroma_db",
    collection_name: str = "world_lore",
    model_name: str = "paraphrase-multilingual-MiniLM-L12-v2",
    clear_collection: bool = False
):
    """Загружает данные лора в ChromaDB с поддержкой upsert"""
    
    # Инициализация модели эмбеддингов
    print(f"Загрузка модели эмбеддингов: {model_name}")
    embedder = SentenceTransformer(model_name)
    
    # Настройка ChromaDB
    print(f"Инициализация ChromaDB в {chroma_path}")
    client = chromadb.PersistentClient(path=chroma_path)
    
    # Очистка коллекции если требуется
    if clear_collection:
        try:
            client.delete_collection(name=collection_name)
            print(f"Коллекция '{collection_name}' удалена")
        except:
            print(f"Коллекция '{collection_name}' не существует для удаления")
    
    # Получение или создание коллекции
    try:
        collection = client.get_collection(name=collection_name)
        print(f"Коллекция '{collection_name}' уже существует, используем её")
    except:
        collection = client.create_collection(name=collection_name, metadata={"hnsw:space": "cosine"})
        print(f"Создана новая коллекция '{collection_name}' с метрикой cosine")
    
    # Обработка и загрузка данных
    total_items = 0
    for item in lore_data:
        doc_id = item.get("id")
        text = item.get("text", "")
        metadata = item.get("metadata", {})
        
        if not doc_id or not text:
            print(f"Пропуск элемента без id или text: {item}")
            continue
        
        # Разбивка текста на чанки если нужно
        chunks = split_text_if_needed(text)
        
        # Подготовка метаданных
        flattened_metadata = flatten_metadata(metadata)
        
        # Вычисление эмбеддингов для всех чанков
        embeddings = embedder.encode(chunks).tolist()
        
        # Upsert для каждого чанка
        for i, (chunk, embedding) in enumerate(zip(chunks, embeddings)):
            chunk_id = f"{doc_id}_chunk_{i}" if len(chunks) > 1 else doc_id
            
            # Добавляем информацию о чанке в метаданные
            chunk_metadata = flattened_metadata.copy()
            if len(chunks) > 1:
                chunk_metadata["chunk_index"] = str(i)
                chunk_metadata["total_chunks"] = str(len(chunks))
            
            collection.upsert(
                ids=[chunk_id],
                embeddings=[embedding],
                documents=[chunk],
                metadatas=[chunk_metadata]
            )
        
        total_items += len(chunks)
        print(f"Загружено {len(chunks)} чанков для id={doc_id}")
    
    print(f"\n✅ Загрузка завершена. Всего загружено {total_items} документов в коллекцию '{collection_name}'")


def main():
    """Главная функция"""
    input_file = "lore_data.txt"
    chroma_path = "./chroma_db"
    collection_name = "world_lore"
    
    if not os.path.exists(input_file):
        print(f"Ошибка: Файл {input_file} не найден")
        return
    
    print(f"Загрузка данных из {input_file}...")
    lore_data = load_lore_data(input_file)
    print(f"Загружено {len(lore_data)} записей из JSON")
    
    ingest_lore_to_chroma(
        lore_data=lore_data,
        chroma_path=chroma_path,
        collection_name=collection_name,
        clear_collection=True  # Удаляет старые данные перед индексацией
    )


if __name__ == "__main__":
    main()
