import pytest

import vocab_store


@pytest.fixture(autouse=True)
def restore_cache():
    original = list(vocab_store._cache)
    yield
    vocab_store._cache = original


def _entry(phrase, sounds_like, enabled=1, entry_id=1):
    return {
        "id": entry_id,
        "phrase": phrase,
        "sounds_like": sounds_like,
        "enabled": enabled,
    }


def test_replacement_treats_backslashes_as_literal_data():
    vocab_store._cache = [_entry(r"\1", "alpha")]
    assert vocab_store.apply_sounds_like("alpha") == r"\1"


def test_ascii_variant_respects_word_boundaries():
    vocab_store._cache = [_entry("dog", "cat")]
    assert vocab_store.apply_sounds_like("concatenate cat category") == "concatenate dog category"


def test_replacement_output_does_not_cascade():
    vocab_store._cache = [
        _entry("bar", "foo", entry_id=1),
        _entry("baz", "bar", entry_id=2),
    ]
    assert vocab_store.apply_sounds_like("foo") == "bar"


def test_longest_variant_wins_at_same_position():
    vocab_store._cache = [_entry("NexVoice", "next voice,next voices")]
    assert vocab_store.apply_sounds_like("next voices") == "NexVoice"


def test_full_width_delimiters_are_normalized():
    assert vocab_store.normalize_sounds_like("next voice，nex voice、nextvoice") == (
        "next voice,nex voice,nextvoice"
    )


def test_control_characters_and_invalid_enabled_are_rejected():
    with pytest.raises(ValueError):
        vocab_store.normalize_phrase("IGNORE\nSYSTEM")
    with pytest.raises(ValueError):
        vocab_store.normalize_enabled(2)
    with pytest.raises(ValueError):
        vocab_store.normalize_enabled("1")
    with pytest.raises(ValueError):
        vocab_store.normalize_phrase("zero\u200bwidth")
    with pytest.raises(ValueError):
        vocab_store.normalize_phrase("line\u2028separator")


def test_bias_prompt_is_byte_bounded():
    vocab_store._cache = [
        _entry(f"專有名詞{i}" + "字" * 20, "", entry_id=i)
        for i in range(vocab_store.MAX_ENTRIES)
    ]
    assert len(vocab_store.get_bias_prompt().encode("utf-8")) <= vocab_store.MAX_BIAS_PROMPT_BYTES


def test_vocabulary_aggregate_size_is_bounded():
    entries = [_entry("x" * 128, "y" * 128, entry_id=i) for i in range(256)]
    assert vocab_store.vocabulary_data_bytes(entries) > vocab_store.MAX_VOCABULARY_DATA_BYTES
