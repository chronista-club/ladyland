//! ロックフリーリングバッファ
//!
//! スレッド間でオーディオデータを効率的に転送するためのリングバッファ。
//! REQ-AUDIO-004: スレッド間通信

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// ロックフリーリングバッファ
///
/// Single-Producer Single-Consumer (SPSC) 向けに最適化
pub struct RingBuffer<T> {
    buffer: Box<[Option<T>]>,
    capacity: usize,
    write_pos: AtomicUsize,
    read_pos: AtomicUsize,
}

impl<T: Clone> RingBuffer<T> {
    /// 指定容量でリングバッファを作成
    pub fn new(capacity: usize) -> Self {
        let buffer: Vec<Option<T>> = (0..capacity).map(|_| None).collect();

        Self {
            buffer: buffer.into_boxed_slice(),
            capacity,
            write_pos: AtomicUsize::new(0),
            read_pos: AtomicUsize::new(0),
        }
    }

    /// 要素をプッシュ（書き込み側）
    ///
    /// バッファが満杯の場合はfalseを返す
    pub fn push(&mut self, item: T) -> bool {
        let write = self.write_pos.load(Ordering::Relaxed);
        let read = self.read_pos.load(Ordering::Acquire);

        let next_write = (write + 1) % self.capacity;

        if next_write == read {
            // バッファ満杯
            return false;
        }

        self.buffer[write] = Some(item);
        self.write_pos.store(next_write, Ordering::Release);
        true
    }

    /// 要素をポップ（読み取り側）
    pub fn pop(&mut self) -> Option<T> {
        let read = self.read_pos.load(Ordering::Relaxed);
        let write = self.write_pos.load(Ordering::Acquire);

        if read == write {
            // バッファ空
            return None;
        }

        let item = self.buffer[read].take();
        let next_read = (read + 1) % self.capacity;
        self.read_pos.store(next_read, Ordering::Release);

        item
    }

    /// バッファ内の要素数
    pub fn len(&self) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Acquire);

        if write >= read {
            write - read
        } else {
            self.capacity - read + write
        }
    }

    /// バッファが空かどうか
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// バッファが満杯かどうか
    pub fn is_full(&self) -> bool {
        self.len() >= self.capacity - 1
    }

    /// 容量を取得
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// バッファをクリア
    pub fn clear(&mut self) {
        while self.pop().is_some() {}
    }
}

/// 分離された読み書きハンドル用のリングバッファ
pub struct SharedRingBuffer<T> {
    inner: Arc<RingBufferInner<T>>,
}

struct RingBufferInner<T> {
    buffer: Box<[std::cell::UnsafeCell<Option<T>>]>,
    capacity: usize,
    write_pos: AtomicUsize,
    read_pos: AtomicUsize,
}

// SAFETY: SPSCパターンで使用することを前提
unsafe impl<T: Send> Send for RingBufferInner<T> {}
unsafe impl<T: Send> Sync for RingBufferInner<T> {}

impl<T> SharedRingBuffer<T> {
    /// 指定容量で共有リングバッファを作成
    pub fn new(capacity: usize) -> (Producer<T>, Consumer<T>) {
        let buffer: Vec<std::cell::UnsafeCell<Option<T>>> =
            (0..capacity).map(|_| std::cell::UnsafeCell::new(None)).collect();

        let inner = Arc::new(RingBufferInner {
            buffer: buffer.into_boxed_slice(),
            capacity,
            write_pos: AtomicUsize::new(0),
            read_pos: AtomicUsize::new(0),
        });

        (
            Producer { inner: inner.clone() },
            Consumer { inner },
        )
    }
}

/// プロデューサー（書き込み側）
pub struct Producer<T> {
    inner: Arc<RingBufferInner<T>>,
}

impl<T> Producer<T> {
    /// 要素をプッシュ
    pub fn push(&self, item: T) -> Result<(), T> {
        let write = self.inner.write_pos.load(Ordering::Relaxed);
        let read = self.inner.read_pos.load(Ordering::Acquire);

        let next_write = (write + 1) % self.inner.capacity;

        if next_write == read {
            return Err(item);
        }

        // SAFETY: write_posは単一のProducerのみがアクセス
        unsafe {
            *self.inner.buffer[write].get() = Some(item);
        }
        self.inner.write_pos.store(next_write, Ordering::Release);
        Ok(())
    }

    /// 利用可能な空き容量
    pub fn available(&self) -> usize {
        let write = self.inner.write_pos.load(Ordering::Relaxed);
        let read = self.inner.read_pos.load(Ordering::Acquire);

        if read > write {
            read - write - 1
        } else {
            self.inner.capacity - write + read - 1
        }
    }
}

/// コンシューマー（読み取り側）
pub struct Consumer<T> {
    inner: Arc<RingBufferInner<T>>,
}

impl<T> Consumer<T> {
    /// 要素をポップ
    pub fn pop(&self) -> Option<T> {
        let read = self.inner.read_pos.load(Ordering::Relaxed);
        let write = self.inner.write_pos.load(Ordering::Acquire);

        if read == write {
            return None;
        }

        // SAFETY: read_posは単一のConsumerのみがアクセス
        let item = unsafe { (*self.inner.buffer[read].get()).take() };
        let next_read = (read + 1) % self.inner.capacity;
        self.inner.read_pos.store(next_read, Ordering::Release);

        item
    }

    /// 利用可能な要素数
    pub fn available(&self) -> usize {
        let write = self.inner.write_pos.load(Ordering::Acquire);
        let read = self.inner.read_pos.load(Ordering::Relaxed);

        if write >= read {
            write - read
        } else {
            self.inner.capacity - read + write
        }
    }
}

// SAFETY: それぞれ独立したスレッドで使用することを前提
unsafe impl<T: Send> Send for Producer<T> {}
unsafe impl<T: Send> Send for Consumer<T> {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_push_pop() {
        let mut rb = RingBuffer::new(4);

        assert!(rb.push(1));
        assert!(rb.push(2));
        assert!(rb.push(3));

        assert_eq!(rb.pop(), Some(1));
        assert_eq!(rb.pop(), Some(2));
        assert_eq!(rb.pop(), Some(3));
        assert_eq!(rb.pop(), None);
    }

    #[test]
    fn test_full_buffer() {
        let mut rb = RingBuffer::new(3);

        assert!(rb.push(1));
        assert!(rb.push(2));
        assert!(!rb.push(3)); // 満杯

        assert_eq!(rb.pop(), Some(1));
        assert!(rb.push(3)); // 空きができた
    }

    #[test]
    fn test_shared_ringbuffer() {
        let (producer, consumer) = SharedRingBuffer::<i32>::new(4);

        assert!(producer.push(1).is_ok());
        assert!(producer.push(2).is_ok());

        assert_eq!(consumer.pop(), Some(1));
        assert_eq!(consumer.pop(), Some(2));
        assert_eq!(consumer.pop(), None);
    }
}
