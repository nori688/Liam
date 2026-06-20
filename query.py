#!/usr/bin/env python3
"""
Скрипт для поиска в базе знаний ChromaDB
"""

from typing import List, Dict, Any
from sentence_transformers import SentenceTransformer
import chromadb


def get_context(
    user_query: str,
    chroma_path: str = "./chroma_db",
    collection_name: str = "world_lore",
    model_name: str = "paraphrase-multilingual-MiniLM-L12-v2",
    n_results: int = 5
) -> List[Dict[str, Any]]:
    """
    Делает запрос к ChromaDB и возвращает релевантные текстовые блоки
    
    Args:
        user_query: Текстовый запрос пользователя
        chroma_path: Путь к директории ChromaDB
        collection_name: Название коллекции
        model_name: Название модели эмбеддингов
        n_results: Количество результатов для возврата (3-5)
    
    Returns:
        Список словарей с полями: text, metadata, distance
    """
    
    # Инициализация модели эмбеддингов
    embedder = SentenceTransformer(model_name)
    
    # Подключение к ChromaDB
    client = chromadb.PersistentClient(path=chroma_path)
    collection = client.get_collection(name=collection_name)
    
    # Вычисление эмбеддинга для запроса
    query_embedding = embedder.encode([user_query]).tolist()
    
    # Поиск в коллекции
    results = collection.query(
        query_embeddings=query_embedding,
        n_results=n_results
    )
    
    # Форматирование результатов
    context_blocks = []
    if results and results.get('documents') and results['documents'][0]:
        for i, (doc, metadata, distance) in enumerate(zip(
            results['documents'][0],
            results['metadatas'][0],
            results['distances'][0]
        )):
            context_blocks.append({
                "text": doc,
                "metadata": metadata,
                "distance": distance,
                "similarity": 1.0 - distance / 2.0  # Преобразование дистанции в сходство
            })
    
    return context_blocks


def print_context(context_blocks: List[Dict[str, Any]]):
    """Выводит результаты поиска в читаемом формате"""
    if not context_blocks:
        print("Ничего не найдено.")
        return
    
    print(f"\nНайдено {len(context_blocks)} релевантных блоков:\n")
    print("=" * 80)
    
    for i, block in enumerate(context_blocks, 1):
        print(f"\n[{i}] Сходство: {block['similarity']:.3f}")
        print(f"Текст: {block['text'][:200]}...")
        print(f"Метаданные: {block['metadata']}")
        print("-" * 80)


def main():
    """Главная функция для тестирования"""
    import sys
    
    if len(sys.argv) < 2:
        print("Использование: python query.py \"ваш запрос\"")
        print("Пример: python query.py \"военная доктрина\"")
        return
    
    query = " ".join(sys.argv[1:])
    print(f"Поиск: {query}")
    
    context = get_context(query)
    print_context(context)


if __name__ == "__main__":
    main()
